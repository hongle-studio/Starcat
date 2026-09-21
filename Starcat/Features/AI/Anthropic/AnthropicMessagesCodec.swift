//
//  AnthropicMessagesCodec.swift
//  Starcat
//
//  Starcat `AIChatRequest` / `AIChatResponse` 与 Anthropic Messages JSON 之间的编解码。
//
//  为什么不让业务层直接说 Anthropic：
//  - Agent / 摘要 / Chat 只认 `user` / `assistant` / `tool`。
//  - Anthropic 没有 `role: tool`，连续 tool 结果必须合并成一条 `user` + 多个 `tool_result`。
//  - `.jsonObject` 不注入假 tool：Haiku / 中转对强制 tool_choice 会 400，
//    auto 又常交空 `{}` 盖掉正文。标签 prompt 已要求 JSON，只在 system 再钉一句。
//
//  关键约束：
//  - `max_tokens` 必填，钳制到 1...32768（Starcat 默认 128K 会被官方拒绝）。
//  - `temperature` 钳制 0...1。
//  - 缺 `toolCallID` 的文案与 OpenAIClient 对齐，避免设置页看到两套说法。
//

import Foundation

/// Anthropic Messages 请求 / 响应编解码。
enum AnthropicMessagesCodec {
    static let jsonResultToolName = "starcat_json_result"
    /// 标签 / 翻译 / RAG 规划都靠 `.jsonObject`；Anthropic 没有 `json_object` 模式。
    static let jsonObjectSystemSuffix = "Return a single JSON object only. No markdown fences, no prose."
    static let apiVersion = "2023-06-01"
    static let maxTokensRange = 1...32_768
    static let allowedImageTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp"
    ]

    /// 把 Starcat 请求编成 Anthropic Messages JSON 对象，供单测直接断言字段。
    static func requestJSONObject(_ request: AIChatRequest, stream: Bool) throws -> [String: Any] {
        let maxTokens = min(max(request.parameters.maxCompletionTokens, maxTokensRange.lowerBound), maxTokensRange.upperBound)
        let temperature = min(max(request.parameters.temperature, 0), 1)

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": stream,
            "messages": try encodeMessages(request)
        ]

        let topP = request.parameters.topP
        if topP > 0, topP < 1 {
            body["top_p"] = topP
        }
        if request.parameters.topK > 0 {
            body["top_k"] = request.parameters.topK
        }

        let systemPrompt = encodedSystemPrompt(request)
        if !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }

        let tools = try encodeTools(request)
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = encodeToolChoice(request)
        }

        return body
    }

    static func requestJSONData(_ request: AIChatRequest, stream: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: try requestJSONObject(request, stream: stream))
    }

    /// 解码非流式 `POST /v1/messages` 响应。
    ///
    /// `failOnTruncation`：正式 chat 遇到 `stop_reason=max_tokens` 必须失败；
    /// 连接测试 ping 只有 8 tokens，中转经常截断，不能当成「输出超上限」。
    static func decodeMessageResponse(
        _ data: Data,
        fallbackModel: String,
        failOnTruncation: Bool = true
    ) throws -> AIChatResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientError.requestFailed(detail: "Anthropic response is not a JSON object")
        }
        return try decodeMessageObject(
            object,
            fallbackModel: fallbackModel,
            failOnTruncation: failOnTruncation
        )
    }

    static func decodeMessageObject(
        _ object: [String: Any],
        fallbackModel: String,
        failOnTruncation: Bool = true
    ) throws -> AIChatResponse {
        let stopReason = (object["stop_reason"] as? String) ?? ""
        if failOnTruncation, stopReason == "max_tokens" {
            throw AIClientError.responseTruncated
        }

        let blocks = object["content"] as? [[String: Any]] ?? []
        var textParts: [String] = []
        var reasoningParts: [String] = []
        var toolCalls: [AIChatToolCall] = []
        var jsonResultContent: String?

        for block in blocks {
            let type = block["type"] as? String
            switch type {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                }
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    reasoningParts.append(thinking)
                }
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                let arguments = jsonString(from: block["input"])
                if name == jsonResultToolName {
                    jsonResultContent = arguments
                } else {
                    toolCalls.append(AIChatToolCall(id: id, name: name, arguments: arguments))
                }
            default:
                continue
            }
        }

        let content = preferredJSONContent(
            toolResult: jsonResultContent,
            text: textParts.joined()
        )
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && toolCalls.isEmpty {
            throw AIClientError.emptyResponse
        }

        let usage = usage(from: object["usage"] as? [String: Any])
        let model = (object["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackModel
        return AIChatResponse(
            content: content,
            reasoningContent: reasoningParts.isEmpty ? nil : reasoningParts.joined(),
            toolCalls: toolCalls,
            usage: usage,
            model: model,
            finishReason: stopReason.isEmpty ? nil : stopReason
        )
    }

    // MARK: - Messages

    private static func encodeMessages(_ request: AIChatRequest) throws -> [[String: Any]] {
        var encoded: [[String: Any]] = []
        let history = request.history
        var index = 0
        while index < history.count {
            let message = history[index]
            switch message.role {
            case .user:
                encoded.append(["role": "user", "content": message.content])
            case .assistant:
                encoded.append(encodeAssistant(message))
            case .tool:
                var group = [message]
                while index + 1 < history.count, history[index + 1].role == .tool {
                    index += 1
                    group.append(history[index])
                }
                encoded.append(try encodeToolResults(group))
            }
            index += 1
        }

        if let currentUser = try encodeCurrentUser(request) {
            encoded.append(currentUser)
        }
        return encoded
    }

    private static func encodeAssistant(_ message: AIChatMessage) -> [String: Any] {
        if message.toolCalls.isEmpty {
            return ["role": "assistant", "content": message.content]
        }

        var blocks: [[String: Any]] = []
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(["type": "text", "text": message.content])
        }
        for call in message.toolCalls {
            blocks.append([
                "type": "tool_use",
                "id": call.id,
                "name": call.name,
                "input": jsonObject(fromArguments: call.arguments)
            ])
        }
        return ["role": "assistant", "content": blocks]
    }

    private static func encodeToolResults(_ messages: [AIChatMessage]) throws -> [String: Any] {
        var blocks: [[String: Any]] = []
        for message in messages {
            guard let toolCallID = message.toolCallID?.nilIfBlank else {
                throw AIClientError.invalidChatHistory("tool message is missing tool_call_id")
            }
            blocks.append([
                "type": "tool_result",
                "tool_use_id": toolCallID,
                "content": message.content
            ])
        }
        return ["role": "user", "content": blocks]
    }

    private static func encodeCurrentUser(_ request: AIChatRequest) throws -> [String: Any]? {
        let text = request.userPrompt
        let images = request.images
        if text.isEmpty && images.isEmpty {
            return nil
        }
        if images.isEmpty {
            return ["role": "user", "content": text]
        }

        var blocks: [[String: Any]] = []
        if !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        for image in images {
            let mediaType = image.contentType.lowercased()
            guard allowedImageTypes.contains(mediaType) else {
                throw AIClientError.requestRejected(
                    statusCode: 400,
                    detail: "Unsupported image type: \(image.contentType)"
                )
            }
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": image.data.base64EncodedString()
                ]
            ])
        }
        return ["role": "user", "content": blocks]
    }

    // MARK: - Tools

    private static func encodedSystemPrompt(_ request: AIChatRequest) -> String {
        let system = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.responseFormat == .jsonObject else { return system }
        if system.isEmpty {
            return jsonObjectSystemSuffix
        }
        if system.contains(jsonObjectSystemSuffix) {
            return system
        }
        return system + "\n\n" + jsonObjectSystemSuffix
    }

    /// 只转发业务自己带的 tools。假 tool 在 Haiku / 中转上要么 400，要么交空 `{}`。
    private static func encodeTools(_ request: AIChatRequest) throws -> [[String: Any]] {
        try request.tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": try jsonObject(from: tool.inputSchema)
            ]
        }
    }

    private static func encodeToolChoice(_ request: AIChatRequest) -> [String: Any] {
        switch request.toolChoice {
        case .none:
            return ["type": "none"]
        case .auto:
            return ["type": "auto"]
        case .required:
            return ["type": "any"]
        case .tool(let name):
            return ["type": "tool", "name": name]
        }
    }

    /// 空 `{}` 不算结构化结果，不能盖掉正文里的 JSON。
    static func preferredJSONContent(toolResult: String?, text: String) -> String {
        if let toolResult, let useful = usefulJSONString(toolResult) {
            return useful
        }
        if let useful = usefulJSONString(text) {
            return useful
        }
        let trimmedTool = toolResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTool.isEmpty {
            return trimmedTool
        }
        return text
    }

    static func usefulJSONString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return nil }
        if let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data),
           !isEmptyJSON(value) {
            return unwrapJSONValue(value) ?? trimmed
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end
        else {
            return nil
        }
        let sliced = String(trimmed[start...end])
        guard sliced != "{}",
              sliced != trimmed,
              let nested = usefulJSONString(sliced)
        else {
            return nil
        }
        return nested
    }

    private static func isEmptyJSON(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] { return dictionary.isEmpty }
        if let array = value as? [Any] { return array.isEmpty }
        return false
    }

    private static func unwrapJSONValue(_ value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            let wrappers: Set<String> = ["result", "data", "json", "output", "value"]
            if dictionary.count == 1,
               let key = dictionary.keys.first,
               wrappers.contains(key.lowercased()) {
                if let nested = dictionary[key] as? [String: Any], !nested.isEmpty {
                    return jsonString(from: nested)
                }
                if let nested = dictionary[key] as? String {
                    return usefulJSONString(nested) ?? nested
                }
            }
            return jsonString(from: dictionary)
        }
        if JSONSerialization.isValidJSONObject(value) {
            return jsonString(from: value)
        }
        return nil
    }

    // MARK: - JSON helpers

    private static func jsonObject(from schema: AgentJSONSchema) throws -> Any {
        let data = try JSONEncoder().encode(schema)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// `AIChatToolCall.arguments` 是字符串。能解析成 object 就原样用；
    /// array / 标量包成 `{ "value": ... }`；解析失败则 `{ "raw": "<原文>" }`，保证回放不丢。
    static func jsonObject(fromArguments arguments: String) -> [String: Any] {
        let data = Data(arguments.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return ["raw": arguments]
        }
        if let dictionary = object as? [String: Any] {
            return dictionary
        }
        return ["value": object]
    }

    static func jsonString(from value: Any?) -> String {
        guard let value else { return "{}" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = value as? String {
            return text
        }
        return "{\"raw\":\(String(describing: value))}"
    }

    static func usage(from object: [String: Any]?) -> AIChatUsage? {
        guard let object else { return nil }
        let input = intValue(object["input_tokens"])
        let output = intValue(object["output_tokens"])
        let cached = intValue(object["cache_read_input_tokens"])
        return AIChatUsage(
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            reasoningTokens: 0,
            totalTokens: input + output
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    /// ping 只认 HTTP 200 + 非 error envelope。thinking 空 text 仍算连通。
    static func throwIfErrorEnvelope(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientError.requestFailed(detail: "Anthropic response is not a JSON object")
        }
        let isError = (object["type"] as? String) == "error" || object["error"] != nil
        if isError {
            throw AIClientError.requestFailed(detail: errorMessage(from: data))
        }
    }

    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return DiagnosticEvent.redact(message)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return DiagnosticEvent.redact(String(raw.prefix(800)))
    }
}

/// 按行解析 Anthropic SSE。取消由外层 Task / URLSession 负责；本类型只做状态累积。
struct AnthropicSSEStreamParser {
    private var pendingEvent = "message"
    private var pendingData = ""
    private var content = ""
    private var toolJSON: [Int: (id: String, name: String, json: String)] = [:]
    private var stopReason: String?
    private var usage: AIChatUsage?
    private var model: String
    private var normalizer = AIStreamReasoningNormalizer()
    private var jsonResultArguments: String?

    init(fallbackModel: String) {
        self.model = fallbackModel
    }

    mutating func ingest(line: String) throws -> [AIChatStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .init(charactersIn: "\r"))
        if trimmed.isEmpty {
            return try flushEvent()
        }
        if trimmed.hasPrefix("event:") {
            // URLSession.bytes.lines 可能丢掉 SSE 分隔空行；遇到新 event 先冲刷上一帧。
            let flushed = pendingData.isEmpty ? [] : try flushEvent()
            pendingEvent = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return flushed
        }
        if trimmed.hasPrefix("data:") {
            let value = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            pendingData = pendingData.isEmpty ? value : pendingData + "\n" + value
            return []
        }
        return []
    }

    mutating func finish() throws -> (events: [AIChatStreamEvent], response: AIChatResponse) {
        var events = try flushEvent()
        events.append(contentsOf: normalizer.finish())
        if stopReason == "max_tokens" {
            throw AIClientError.responseTruncated
        }
        let response = try makeResponse()
        events.append(.completed(response))
        return (events, response)
    }

    private mutating func flushEvent() throws -> [AIChatStreamEvent] {
        let event = pendingEvent
        let data = pendingData
        pendingEvent = "message"
        pendingData = ""
        guard !data.isEmpty, data != "[DONE]", event != "ping" else { return [] }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else {
            return []
        }
        return try handle(event: event, object: object)
    }

    private mutating func handle(event: String, object: [String: Any]) throws -> [AIChatStreamEvent] {
        switch event {
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any],
               (block["type"] as? String) == "tool_use" {
                let index = intValue(object["index"])
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                toolJSON[index] = (id, name, "")
            }
            return []
        case "content_block_delta":
            return try handleDelta(object)
        case "message_delta":
            if let delta = object["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String,
               !reason.isEmpty {
                stopReason = reason
            }
            if let usageObject = object["usage"] as? [String: Any] {
                usage = mergeUsage(usage, AnthropicMessagesCodec.usage(from: usageObject))
            }
            if let usage, usage.totalTokens > 0 {
                return [.usage(usage)]
            }
            return []
        case "message_start":
            if let message = object["message"] as? [String: Any] {
                if let id = message["model"] as? String, !id.isEmpty {
                    model = id
                }
                if let usageObject = message["usage"] as? [String: Any] {
                    usage = mergeUsage(usage, AnthropicMessagesCodec.usage(from: usageObject))
                }
            }
            return []
        default:
            return []
        }
    }

    private mutating func handleDelta(_ object: [String: Any]) throws -> [AIChatStreamEvent] {
        guard let delta = object["delta"] as? [String: Any] else { return [] }
        let type = delta["type"] as? String
        switch type {
        case "text_delta":
            let text = delta["text"] as? String ?? ""
            content += text
            return normalizer.ingest(content: text, nativeReasoning: nil)
        case "thinking_delta":
            let thinking = delta["thinking"] as? String ?? ""
            return normalizer.ingest(content: nil, nativeReasoning: thinking)
        case "input_json_delta":
            let index = intValue(object["index"])
            let fragment = delta["partial_json"] as? String ?? ""
            if var partial = toolJSON[index] {
                partial.json += fragment
                toolJSON[index] = partial
            } else {
                toolJSON[index] = ("", "", fragment)
            }
            let name = toolJSON[index]?.name ?? ""
            if name == AnthropicMessagesCodec.jsonResultToolName {
                jsonResultArguments = (jsonResultArguments ?? "") + fragment
                return []
            }
            return [.toolCallDelta(AIChatToolCallDelta(
                index: index,
                id: toolJSON[index]?.id,
                name: name.isEmpty ? nil : name,
                argumentsFragment: fragment
            ))]
        default:
            return []
        }
    }

    private func makeResponse() throws -> AIChatResponse {
        var toolCalls: [AIChatToolCall] = []
        for key in toolJSON.keys.sorted() {
            guard let partial = toolJSON[key] else { continue }
            if partial.name == AnthropicMessagesCodec.jsonResultToolName {
                continue
            }
            if partial.id.isEmpty && partial.name.isEmpty && partial.json.isEmpty {
                continue
            }
            toolCalls.append(AIChatToolCall(
                id: partial.id.isEmpty ? UUID().uuidString : partial.id,
                name: partial.name,
                arguments: partial.json.isEmpty ? "{}" : partial.json
            ))
        }
        let jsonContent = AnthropicMessagesCodec.preferredJSONContent(
            toolResult: jsonResultArguments,
            text: content
        )
        if jsonContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && toolCalls.isEmpty {
            throw AIClientError.emptyResponse
        }
        return AIChatResponse(
            content: jsonContent,
            reasoningContent: nil,
            toolCalls: toolCalls,
            usage: usage,
            model: model,
            finishReason: stopReason
        )
    }

    private func mergeUsage(_ lhs: AIChatUsage?, _ rhs: AIChatUsage?) -> AIChatUsage? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let input = max(lhs.inputTokens, rhs.inputTokens)
        let output = max(lhs.outputTokens, rhs.outputTokens)
        let cached = max(lhs.cachedTokens, rhs.cachedTokens)
        return AIChatUsage(
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            reasoningTokens: 0,
            totalTokens: input + output
        )
    }

    private func intValue(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
