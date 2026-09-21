//
//  AnthropicMessagesCodecTests.swift
//  StarcatTests
//
//  覆盖历史 tool 合并、jsonObject 正文 JSON、max_tokens 钳制、stop_reason 映射。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AnthropicMessagesCodec")
struct AnthropicMessagesCodecTests {
    @Test("system 为空则省略，单轮 user 进入 messages")
    func systemAndSingleUser() throws {
        let object = try AnthropicMessagesCodec.requestJSONObject(
            AIChatRequest(
                systemPrompt: "You are helpful",
                userPrompt: "hi",
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault
            ),
            stream: false
        )
        #expect(object["system"] as? String == "You are helpful")
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "hi")
    }

    @Test("相邻两条 tool 结果合并成一条 user 含两个 tool_result")
    func mergesConsecutiveToolResults() throws {
        let object = try AnthropicMessagesCodec.requestJSONObject(
            AIChatRequest(
                systemPrompt: "",
                userPrompt: "",
                history: [
                    .init(role: .user, content: "search"),
                    .init(
                        role: .assistant,
                        toolCalls: [
                            .init(id: "call-1", name: "external_search", arguments: "{\"query\":\"Swift\"}"),
                            .init(id: "call-2", name: "external_search", arguments: "{\"query\":\"Combine\"}")
                        ]
                    ),
                    .init(role: .tool, content: "{\"items\":[]}", toolCallID: "call-1"),
                    .init(role: .tool, content: "{\"items\":[1]}", toolCallID: "call-2")
                ],
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault
            ),
            stream: false
        )
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.contains { $0["role"] as? String == "tool" } == false)
        let userWithTools = try #require(messages.last)
        #expect(userWithTools["role"] as? String == "user")
        let blocks = try #require(userWithTools["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "tool_result")
        #expect(blocks[0]["tool_use_id"] as? String == "call-1")
        #expect(blocks[1]["tool_use_id"] as? String == "call-2")
    }

    @Test("tool 缺 id 抛 invalidChatHistory")
    func missingToolCallID() {
        #expect(throws: AIClientError.self) {
            _ = try AnthropicMessagesCodec.requestJSONObject(
                AIChatRequest(
                    systemPrompt: "",
                    userPrompt: "",
                    history: [.init(role: .tool, content: "{}")],
                    model: "claude-sonnet-4-5",
                    parameters: .summaryDefault
                ),
                stream: false
            )
        }
    }

    @Test("jsonObject 不注入假 tool，system 追加 JSON only")
    func jsonObjectDoesNotInjectDummyTool() throws {
        let object = try AnthropicMessagesCodec.requestJSONObject(
            AIChatRequest(
                systemPrompt: "",
                userPrompt: "return json",
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault,
                responseFormat: .jsonObject
            ),
            stream: false
        )
        #expect(object["tools"] == nil)
        #expect(object["tool_choice"] == nil)
        #expect(object["system"] as? String == AnthropicMessagesCodec.jsonObjectSystemSuffix)
    }

    @Test("空 starcat_json_result 不能盖掉正文 JSON")
    func emptyJSONToolFallsBackToText() throws {
        let data = Data(#"""
        {
          "content": [
            {
              "type": "tool_use",
              "id": "toolu-1",
              "name": "starcat_json_result",
              "input": {}
            },
            {
              "type": "text",
              "text": "{\"suggestedTags\":[{\"name\":\"Swift\",\"confidence\":0.9,\"reason\":\"lang\"}]}"
            }
          ],
          "stop_reason": "end_turn",
          "model": "claude-haiku-4-5"
        }
        """#.utf8)
        let response = try AnthropicMessagesCodec.decodeMessageResponse(
            data,
            fallbackModel: "claude-haiku-4-5"
        )
        #expect(response.content.contains("suggestedTags"))
        #expect(response.toolCalls.isEmpty)
    }

    @Test("max_tokens 128K 被钳成 32768")
    func clampsMaxTokens() throws {
        let object = try AnthropicMessagesCodec.requestJSONObject(
            AIChatRequest(
                systemPrompt: "",
                userPrompt: "hi",
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault
            ),
            stream: false
        )
        #expect(object["max_tokens"] as? Int == 32_768)
    }

    @Test("stop_reason=max_tokens 映射 responseTruncated")
    func truncatedStopReason() throws {
        let data = Data(#"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens","model":"claude-sonnet-4-5"}"#.utf8)
        #expect(throws: AIClientError.responseTruncated) {
            _ = try AnthropicMessagesCodec.decodeMessageResponse(data, fallbackModel: "claude-sonnet-4-5")
        }
    }

    @Test("连接测试允许 ping 被 max_tokens 截断")
    func pingIgnoresTruncation() throws {
        let data = Data(#"{"content":[{"type":"text","text":"p"}],"stop_reason":"max_tokens","model":"claude-sonnet-4-5"}"#.utf8)
        let response = try AnthropicMessagesCodec.decodeMessageResponse(
            data,
            fallbackModel: "claude-sonnet-4-5",
            failOnTruncation: false
        )
        #expect(response.content == "p")
        #expect(response.finishReason == "max_tokens")
    }

    @Test("error envelope 失败；message 即使只有 thinking 也通过")
    func pingEnvelopeCheck() throws {
        let errorData = Data(#"{"type":"error","error":{"message":"nope"}}"#.utf8)
        #expect(throws: AIClientError.self) {
            try AnthropicMessagesCodec.throwIfErrorEnvelope(errorData)
        }
        let thinkingOnly = Data(#"{"type":"message","content":[{"type":"thinking","thinking":"x"}],"stop_reason":"max_tokens"}"#.utf8)
        try AnthropicMessagesCodec.throwIfErrorEnvelope(thinkingOnly)
    }

    @Test("starcat_json_result 进入 content 而不进入 toolCalls")
    func jsonResultUnwrapped() throws {
        let data = Data(#"""
        {
          "content": [
            {
              "type": "tool_use",
              "id": "toolu-1",
              "name": "starcat_json_result",
              "input": {"hello": "world"}
            }
          ],
          "stop_reason": "tool_use",
          "model": "claude-sonnet-4-5",
          "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """#.utf8)
        let response = try AnthropicMessagesCodec.decodeMessageResponse(
            data,
            fallbackModel: "claude-sonnet-4-5"
        )
        #expect(response.toolCalls.isEmpty)
        #expect(response.content.contains("hello"))
        #expect(response.usage?.totalTokens == 15)
    }
}
