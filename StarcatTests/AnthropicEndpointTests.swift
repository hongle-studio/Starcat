//
//  AnthropicEndpointTests.swift
//  StarcatTests
//
//  覆盖 Anthropic Base URL 归一：官方、带 /v1、DeepSeek /anthropic 中转、非法输入。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AnthropicEndpoint")
struct AnthropicEndpointTests {
    @Test("官方根路径拼 /v1/messages 与 /v1/models")
    func officialRoot() throws {
        let endpoint = try AnthropicEndpoint.normalize(baseURL: "https://api.anthropic.com")
        #expect(endpoint.messagesURL.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(endpoint.modelsURL.absoluteString == "https://api.anthropic.com/v1/models")
    }

    @Test("已以 /v1 结尾时不再重复 v1")
    func alreadyV1() throws {
        let endpoint = try AnthropicEndpoint.normalize(baseURL: "https://api.anthropic.com/v1")
        #expect(endpoint.messagesURL.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(endpoint.modelsURL.absoluteString == "https://api.anthropic.com/v1/models")
    }

    @Test("DeepSeek 根路径不会被插入 /anthropic")
    func deepSeekRootDoesNotInsertAnthropic() throws {
        let endpoint = try AnthropicEndpoint.normalize(baseURL: "https://api.deepseek.com")
        #expect(endpoint.messagesURL.absoluteString == "https://api.deepseek.com/v1/messages")
        #expect(endpoint.modelsURL.absoluteString == "https://api.deepseek.com/v1/models")
        #expect(!endpoint.messagesURL.path.contains("/anthropic"))
    }

    @Test("中转根地址提供 /anthropic 候选")
    func deepSeekRootCandidate() throws {
        let endpoint = try AnthropicEndpoint.normalize(baseURL: "https://api.deepseek.com")
        let alt = try #require(try endpoint.anthropicPathCandidate())
        #expect(alt.normalizedBaseURL == "https://api.deepseek.com/anthropic")
        #expect(alt.messagesURL.absoluteString == "https://api.deepseek.com/anthropic/v1/messages")
    }

    @Test("官方与已有 /anthropic 不再补 path")
    func noCandidateWhenOfficialOrAlreadyPresent() throws {
        #expect(try AnthropicEndpoint.normalize(baseURL: "https://api.anthropic.com").anthropicPathCandidate() == nil)
        #expect(try AnthropicEndpoint.normalize(baseURL: "https://api.deepseek.com/anthropic").anthropicPathCandidate() == nil)
    }

    @Test("已带 /v1 时把 /anthropic 插在 v1 前面")
    func insertsAnthropicBeforeV1() throws {
        let endpoint = try AnthropicEndpoint.normalize(baseURL: "https://relay.example.com/v1")
        let alt = try #require(try endpoint.anthropicPathCandidate())
        #expect(alt.normalizedBaseURL == "https://relay.example.com/anthropic/v1")
        #expect(alt.messagesURL.absoluteString == "https://relay.example.com/anthropic/v1/messages")
    }

    @Test("DeepSeek /anthropic 中转保留 anthropic path")
    func deepSeekAnthropic() throws {
        let endpoint = try AnthropicEndpoint.normalize(baseURL: "https://api.deepseek.com/anthropic")
        #expect(endpoint.messagesURL.absoluteString == "https://api.deepseek.com/anthropic/v1/messages")
        #expect(endpoint.modelsURL.absoluteString == "https://api.deepseek.com/anthropic/v1/models")
    }

    @Test("DeepSeek /anthropic/v1 只再拼 messages")
    func deepSeekAnthropicV1() throws {
        let endpoint = try AnthropicEndpoint.normalize(baseURL: "https://api.deepseek.com/anthropic/v1")
        #expect(endpoint.messagesURL.absoluteString == "https://api.deepseek.com/anthropic/v1/messages")
        #expect(endpoint.modelsURL.absoluteString == "https://api.deepseek.com/anthropic/v1/models")
    }

    @Test("末尾多个斜杠剥到稳定")
    func trailingSlashes() throws {
        let endpoint = try AnthropicEndpoint.normalize(baseURL: "https://api.anthropic.com///")
        #expect(endpoint.normalizedBaseURL == "https://api.anthropic.com")
        #expect(endpoint.messagesURL.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test("空串、无 scheme、仅 path 均视为非法 URL")
    func invalidInputs() {
        let samples = ["", "   ", "api.anthropic.com", "/v1", "ftp://api.anthropic.com"]
        for sample in samples {
            #expect(throws: AIClientError.self) {
                _ = try AnthropicEndpoint.normalize(baseURL: sample)
            }
        }
    }
}
