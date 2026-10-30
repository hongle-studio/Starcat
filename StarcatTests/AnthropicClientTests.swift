//
//  AnthropicClientTests.swift
//  StarcatTests
//
//  用 URLProtocolStub 覆盖 chat / SSE / listModels 回落 / 鉴权失败 / embedding 拒绝 / 取消。
//  Suite 串行：URLProtocolStub 使用进程级静态 handler。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AnthropicClient", .serialized)
struct AnthropicClientTests {
    private func makeClient(baseURL: String = "https://api.anthropic.com") throws -> AnthropicClient {
        try AnthropicClient(
            configuration: AIClientConfiguration(
                providerID: "anthropic-test",
                provider: .anthropic,
                apiKey: "sk-test-xxxx",
                baseURL: baseURL,
                chatModel: "claude-sonnet-4-5",
                embeddingModel: ""
            ),
            session: URLProtocolStub.ephemeralSession()
        )
    }

    private func jsonResponse(_ status: Int, url: URL, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    @Test("非流式 text 200 返回 content 与 usage")
    func chatTextSuccess() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test-xxxx")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-xxxx")
            let url = try #require(request.url)
            return jsonResponse(
                200,
                url: url,
                body: #"""
                {
                  "content": [{"type": "text", "text": "hello from claude"}],
                  "stop_reason": "end_turn",
                  "model": "claude-sonnet-4-5",
                  "usage": {"input_tokens": 12, "output_tokens": 4}
                }
                """#
            )
        }

        let client = try makeClient()
        let response = try await client.chat(request: AIChatRequest(
            systemPrompt: "sys",
            userPrompt: "hi",
            model: "claude-sonnet-4-5",
            parameters: .summaryDefault
        ))
        #expect(response.content == "hello from claude")
        #expect(response.usage?.inputTokens == 12)
        #expect(response.usage?.outputTokens == 4)
        let body = String(data: URLProtocolStub.receivedRequests.first?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!body.contains("thinking"))
    }

    @Test("流式两帧 text_delta 后 completed")
    func chatStreamDeltas() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let url = try #require(request.url)
            let sse = """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

            event: message_stop
            data: {"type":"message_stop"}

            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(sse.utf8))
        }

        let client = try makeClient()
        var deltas: [String] = []
        var completed: AIChatResponse?
        for try await event in client.chatStream(request: AIChatRequest(
            systemPrompt: "",
            userPrompt: "hi",
            model: "claude-sonnet-4-5",
            parameters: .summaryDefault
        )) {
            switch event {
            case .delta(let text):
                deltas.append(text)
            case .completed(let response):
                completed = response
            default:
                break
            }
        }
        #expect(deltas == ["Hello", " world"])
        #expect(completed?.content == "Hello world")
    }

    @Test("401 JSON error 映射 authenticationRejected 且详情不含完整 Key")
    func authenticationRejected() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let url = try #require(request.url)
            return jsonResponse(
                401,
                url: url,
                body: #"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
            )
        }

        let client = try makeClient()
        do {
            _ = try await client.chat(request: AIChatRequest(
                systemPrompt: "",
                userPrompt: "hi",
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault
            ))
            Issue.record("expected authenticationRejected")
        } catch let error as AIClientError {
            guard case .authenticationRejected(let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(!detail.contains("sk-test-xxxx"))
        }
    }

    @Test("/models 404 回落 bundled 并随后 ping messages")
    func models404FallsBackAndPings() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/models") {
                return jsonResponse(404, url: url, body: #"{"error":{"message":"not found"}}"#)
            }
            return jsonResponse(
                200,
                url: url,
                body: #"""
                {
                  "content": [{"type": "text", "text": "pong"}],
                  "stop_reason": "end_turn",
                  "model": "claude-sonnet-4-5",
                  "usage": {"input_tokens": 1, "output_tokens": 1}
                }
                """#
            )
        }

        let client = try makeClient()
        let models = try await client.listModels()
        #expect(!models.isEmpty)
        #expect(models.contains { $0.name == "claude-sonnet-4-5" })
        let paths = URLProtocolStub.receivedRequests.compactMap(\.url?.path)
        #expect(paths.contains { $0.hasSuffix("/models") })
        #expect(paths.contains { $0.hasSuffix("/messages") })
    }

    @Test("/models 404 后 ping 被 max_tokens 截断仍算连接成功")
    func models404PingTruncationStillSucceeds() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/models") {
                return jsonResponse(404, url: url, body: #"{"error":{"message":"not found"}}"#)
            }
            return jsonResponse(
                200,
                url: url,
                body: #"""
                {
                  "content": [{"type": "text", "text": "p"}],
                  "stop_reason": "max_tokens",
                  "model": "claude-sonnet-4-5",
                  "usage": {"input_tokens": 1, "output_tokens": 8}
                }
                """#
            )
        }

        let client = try makeClient()
        let models = try await client.listModels()
        #expect(!models.isEmpty)
    }

    @Test("/models 200 无 data 时回落 ping，thinking 空 text 仍算成功")
    func models200UnparseableThinkingPingSucceeds() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/models") {
                return jsonResponse(200, url: url, body: #"{"type":"error","error":{"message":"no models"}}"#)
            }
            return jsonResponse(
                200,
                url: url,
                body: #"""
                {
                  "type": "message",
                  "content": [{"type": "thinking", "thinking": "plan"}],
                  "stop_reason": "max_tokens",
                  "model": "deepseek-v4-flash",
                  "usage": {"input_tokens": 1, "output_tokens": 8}
                }
                """#
            )
        }

        let client = try makeClient()
        let models = try await client.listModels()
        #expect(models.contains { $0.name == "claude-sonnet-4-5" })
        let paths = URLProtocolStub.receivedRequests.compactMap(\.url?.path)
        #expect(paths.contains { $0.hasSuffix("/models") })
        #expect(paths.contains { $0.hasSuffix("/messages") })
    }

    @Test("根地址 Messages 404 时改走 /anthropic 并记下 Base URL")
    func retriesAnthropicPathAndRecordsBaseURL() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1/models":
                return jsonResponse(
                    200,
                    url: url,
                    body: #"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#
                )
            case "/v1/messages", "/anthropic/v1/models":
                return jsonResponse(404, url: url, body: #"{"error":{"message":"not found"}}"#)
            case "/anthropic/v1/messages":
                return jsonResponse(
                    200,
                    url: url,
                    body: #"{"type":"message","content":[{"type":"thinking","thinking":"x"}],"stop_reason":"max_tokens"}"#
                )
            default:
                Issue.record("unexpected path \(url.path)")
                return jsonResponse(500, url: url, body: "{}")
            }
        }

        let client = try makeClient(baseURL: "https://api.deepseek.com")
        let models = try await client.listModels()
        #expect(models.contains { $0.name == "deepseek-chat" })
        #expect(client.probedBaseURL == "https://api.deepseek.com/anthropic")
    }

    @Test("官方地址不补 /anthropic")
    func officialDoesNotRetryAnthropicPath() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let url = try #require(request.url)
            #expect(!url.path.contains("/anthropic"))
            if url.path.hasSuffix("/models") {
                return jsonResponse(404, url: url, body: #"{"error":{"message":"not found"}}"#)
            }
            return jsonResponse(
                200,
                url: url,
                body: #"{"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
            )
        }

        let client = try makeClient()
        _ = try await client.listModels()
        #expect(client.probedBaseURL == "https://api.anthropic.com")
    }

    @Test("/models 401 失败且不回落目录")
    func models401DoesNotFallback() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let url = try #require(request.url)
            return jsonResponse(401, url: url, body: #"{"error":{"message":"bad key"}}"#)
        }

        let client = try makeClient()
        do {
            _ = try await client.listModels()
            Issue.record("expected authenticationRejected")
        } catch let error as AIClientError {
            guard case .authenticationRejected = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        #expect(URLProtocolStub.receivedRequests.allSatisfy { $0.url?.path.hasSuffix("/models") == true })
    }

    @Test("embedding 直接拒绝")
    func embeddingRejected() async throws {
        URLProtocolStub.reset()
        let client = try makeClient()
        do {
            _ = try await client.embedding(input: "hi", model: nil)
            Issue.record("expected requestRejected")
        } catch let error as AIClientError {
            guard case .requestRejected(let status, let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(status == 400)
            #expect(detail.contains("embeddings"))
        }
    }

    @Test("URLSession 取消映射为 CancellationError")
    func cancellation() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { _ in
            throw URLError(.cancelled)
        }
        let client = try makeClient()
        do {
            _ = try await client.chat(request: AIChatRequest(
                systemPrompt: "",
                userPrompt: "hi",
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault
            ))
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
