//
//  AnthropicEndpoint.swift
//  Starcat
//
//  把用户填写的 Anthropic Base URL 归一成 messages 与 models 端点。
//
//  为什么单独抽出来：
//  - 官方是 `https://api.anthropic.com`，中转常见根地址或 `*/anthropic`。
//  - 归一只拼 `/v1/messages`，不改写用户已写的 `/anthropic`。
//  - 测连接时若 Messages 404/405，再用 `anthropicPathCandidate()` 补一层 `/anthropic`。
//
//  关键约束：
//  - 只剥末尾 `/`；path 已以 `/v1` 结尾时只再拼 `/messages` 与 `/models`。
//  - `api.anthropic.com` 与已经含 `/anthropic` 的地址禁止再补 path。
//

import Foundation

/// Anthropic Messages API 的归一化端点。
struct AnthropicEndpoint: Equatable, Sendable {
    let messagesURL: URL
    let modelsURL: URL
    let normalizedBaseURL: String

    /// 将用户输入的 Base URL 归一成可请求的 messages / models URL。
    ///
    /// - Throws: `AIClientError.invalidBaseURL`（空串、缺 scheme、缺 host、非 http(s)）。
    static func normalize(baseURL: String) throws -> AnthropicEndpoint {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else {
            throw AIClientError.invalidBaseURL(baseURL)
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              host.isEmpty == false
        else {
            throw AIClientError.invalidBaseURL(baseURL)
        }

        let path = url.path
        let alreadyV1 = path == "/v1" || path.hasSuffix("/v1")
        let messagesString = alreadyV1 ? "\(trimmed)/messages" : "\(trimmed)/v1/messages"
        let modelsString = alreadyV1 ? "\(trimmed)/models" : "\(trimmed)/v1/models"
        guard let messagesURL = URL(string: messagesString),
              let modelsURL = URL(string: modelsString)
        else {
            throw AIClientError.invalidBaseURL(baseURL)
        }

        return AnthropicEndpoint(
            messagesURL: messagesURL,
            modelsURL: modelsURL,
            normalizedBaseURL: trimmed
        )
    }

    /// 中转根地址在 Messages 404 时的 `/anthropic` 候选。官方与已经带该 path 的返回 `nil`。
    func anthropicPathCandidate() throws -> AnthropicEndpoint? {
        guard let url = URL(string: normalizedBaseURL),
              let host = url.host?.lowercased(),
              host.isEmpty == false
        else {
            return nil
        }
        if host == "api.anthropic.com" || host.hasSuffix(".anthropic.com") {
            return nil
        }
        let segments = url.path.split(separator: "/").map { $0.lowercased() }
        if segments.contains("anthropic") {
            return nil
        }

        var stem = normalizedBaseURL
        let hadV1 = url.path == "/v1" || url.path.hasSuffix("/v1")
        if hadV1, stem.lowercased().hasSuffix("/v1") {
            stem.removeLast(3)
            while stem.hasSuffix("/") {
                stem.removeLast()
            }
        }
        let candidate = hadV1 ? "\(stem)/anthropic/v1" : "\(stem)/anthropic"
        return try AnthropicEndpoint.normalize(baseURL: candidate)
    }
}
