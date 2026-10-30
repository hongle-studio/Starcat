//
//  LocalAIInferenceSmokeTests.swift
//  StarcatTests
//
//  显式启用的本地权重冒烟，不进入日常单测。仅复用已安装文件，不下载、不访问用户数据。
//  执行：TEST_RUNNER_STARCAT_LOCAL_AI_SMOKE=1 TEST_RUNNER_STARCAT_LOCAL_AI_SMOKE_ROOT=/path/to/models make test
//       TEST_ARGS="-only-testing:StarcatTests/LocalAIInferenceSmokeTests"
//

import Foundation
import MLX
import MLXLLM
import Testing
@testable import Starcat

/// 独立测试进程内逐个加载；不解除生产 runtime 的 TestEnvironment 防护。
@Suite("LocalAIInferenceSmoke", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["STARCAT_LOCAL_AI_SMOKE"] == "1"))
struct LocalAIInferenceSmokeTests {
    @Test("已安装 MiniCPM / Qwen3 的有界生成、真实截断与释放")
    func generatesAndReleasesModels() async throws {
        // 测试宿主默认使用隔离目录；只有显式传入的目录可用于这个只读冒烟。
        let root = try #require(ProcessInfo.processInfo.environment["STARCAT_LOCAL_AI_SMOKE_ROOT"])
        let previousRoot = LocalAIModelStorage.testRootOverride
        LocalAIModelStorage.testRootOverride = URL(fileURLWithPath: root, isDirectory: true)
        defer { LocalAIModelStorage.testRootOverride = previousRoot }
        let previousLimit = Memory.memoryLimit
        let previousCache = Memory.cacheLimit
        let budget = 4 * 1_024 * 1_024 * 1_024
        Memory.memoryLimit = budget
        Memory.cacheLimit = 256 * 1_024 * 1_024
        defer {
            Memory.clearCache()
            Memory.cacheLimit = previousCache
            Memory.memoryLimit = previousLimit
        }
        for entry in [LocalAIModelCatalog.llmMiniCPM5, LocalAIModelCatalog.llmLite] {
            let directory = try #require(LocalAIModelStorage.installedDirectoryURL(entryID: entry.id))
            let before = Memory.activeMemory
            let response = try await Self.exerciseModel(entry: entry, directory: directory)
            #expect(response.model == entry.displayName)
            #expect(response.finishReason == "stop")
            #expect(!response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect((response.usage?.outputTokens ?? 0) > 0)
            Memory.clearCache()
            // 权重应随独立任务退出而释放；容许少量 Metal 运行时常驻分配。
            #expect(Memory.activeMemory < before + 32 * 1_024 * 1_024)
            #expect(Memory.peakMemory <= budget)
            print("LocalAI smoke model=\(entry.displayName) finish=\(response.finishReason ?? "nil") tokens=\(response.usage?.outputTokens ?? 0) peak=\(Memory.peakMemory) activeAfter=\(Memory.activeMemory)")
        }
    }

    /// 限制加载、短生成及中途取消的总耗时；只返回纯文本，不能让容器逃逸到断言阶段。
    private static func exerciseModel(entry: LocalAIModelCatalogEntry, directory: URL) async throws -> AIChatResponse {
        try await LocalAIGenerationPolicy.withTimeout(seconds: 60) {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: directory, using: LocalMLXRuntime.tokenizerLoader)
            var parameters = LocalAIGenerationPolicy.defaultParameters(model: entry.displayName, capability: .chat)
            parameters.maxCompletionTokens = 256
            var request = AIChatRequest(
                systemPrompt: "Write concise technical notes. Do not repeat sections.",
                userPrompt: "# Starcat\nStarcat is a macOS GitHub stars manager with local search and AI summaries.\n请用中文写三条简短的使用笔记。",
                model: entry.displayName, parameters: parameters)
            request.disableThinking = true
            let response = try await LocalMLXRuntime.generate(container: container, request: request) { _ in }
            // 单 token 上限必然不足以完成这个请求；SDK 的 length 必须原样传到业务保护层。
            var limited = request
            limited.parameters.maxCompletionTokens = 1
            let truncated = try await LocalMLXRuntime.generate(container: container, request: limited) { _ in }
            #expect(truncated.finishReason == "length")
            #expect(throws: AIClientError.responseTruncated) {
                try LocalAIGenerationPolicy.validateCompletion(truncated)
            }
            // 在第一个流事件后主动取消，验证 GPU producer 退出后才返回，而不只测试正常释放。
            let signal = AsyncStream<Void>.makeStream()
            let cancellable = Task {
                defer { signal.continuation.finish() }
                return try await LocalMLXRuntime.generate(container: container, request: request) { _ in
                    signal.continuation.yield(())
                }
            }
            let result = await withTaskCancellationHandler {
                var iterator = signal.stream.makeAsyncIterator()
                _ = await iterator.next()
                cancellable.cancel()
                return await cancellable.result
            } onCancel: {
                cancellable.cancel()
            }
            if case .failure(let error) = result {
                #expect(error is CancellationError)
            } else {
                Issue.record("Generation should have been cancelled")
            }
            return response
        }
    }
}
