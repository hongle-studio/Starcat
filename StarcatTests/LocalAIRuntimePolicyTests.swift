//
//  LocalAIRuntimePolicyTests.swift
//  StarcatTests
//
//  回归验证 GPU 准入、取消排队和配置释放策略。用可控异步任务替代真实模型，常规单测
//  不加载 Metal，也不消耗开发机数 GB 内存。
//

import Foundation
import Testing

@testable import Starcat

@Suite("LocalAIRuntimePolicy", .timeLimit(.minutes(1)))
struct LocalAIRuntimePolicyTests {
    private actor ConcurrencyProbe {
        var active = 0
        var peak = 0
        func enter() {
            active += 1
            peak = max(active, peak)
        }
        func leave() { active -= 1 }
    }

    @Test("不同任务共享 GPU 准入且 await 期间不会重入")
    func serializesCompleteOperations() async throws {
        let gate = LocalAIOperationGate()
        let probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await gate.acquire()
                    await probe.enter()
                    try await Task.sleep(for: .milliseconds(2))
                    await probe.leave()
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.peak == 1)
        #expect(await probe.active == 0)
    }

    @Test("排队取消不会阻塞后续卸载或新请求")
    func cancelledWaiterDoesNotConsumePermit() async throws {
        let gate = LocalAIOperationGate()
        try await gate.acquire()
        let waiter = Task {
            try await gate.acquire()
            await gate.release()
        }
        for _ in 0..<10 { await Task.yield() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await gate.release()
        try await gate.acquire()
        await gate.release()
    }

    @Test("大内存 Mac 不再继承数十 GB GPU 预算")
    func boundedMemoryBudget() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        #expect(LocalAIMemoryPolicy.budget(physicalMemory: 64 * gib) == 8 * Int(gib))
        #expect(LocalAIMemoryPolicy.budget(physicalMemory: 16 * gib) == 4 * Int(gib))
        #expect(LocalAIMemoryPolicy.budget(physicalMemory: 8 * gib) == 2 * Int(gib))
    }

    @Test("对话改用 API 仍保留其它功能正在配置的本地模型")
    @MainActor func retainsOtherLocalFeatures() {
        let suite = "LocalAIRuntimePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.aiProviderProfiles = [
            AIProviderProfile(
                id: "test-local-runtime", provider: .localAI, models: [], lastTestStatus: .notTested)
        ]
        settings.aiChatTask.providerID = "test-api"
        settings.aiEmbeddingTask.providerID = "test-local-runtime"
        settings.aiEmbeddingTask.modelID = "test-local-embedding"
        settings.aiEmbeddingTask.useCustomModel = false
        let embedding = LocalAIModelCatalog.embedding
        settings.localAIModelSelections["embedding"] = embedding.id
        #expect(settings.configuredLocalAIModelNames.contains(embedding.displayName))
        #expect(!settings.configuredLocalAIModelNames.contains("test-local-embedding"))
        #expect(!settings.configuredLocalAIModelNames.contains(settings.aiChatTask.resolvedModelName))
    }

    @Test("相同的空任务配置按类别保留本地选择，不沿用远程 fallback")
    @MainActor func fallbackModelsAreResolvedByTaskKind() {
        let suite = "LocalAIRuntimePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.aiProviderProfiles = [
            AIProviderProfile(
                id: "test-local-runtime", provider: .localAI, models: [], lastTestStatus: .notTested)
        ]
        settings.aiChatModel = "fallback-chat"
        settings.aiEmbeddingModel = "fallback-embedding"
        settings.aiChatTask.providerID = "test-local-runtime"
        settings.aiChatTask.modelID = ""
        settings.aiChatTask.useCustomModel = false
        settings.aiEmbeddingTask = settings.aiChatTask
        let chat = settings.selectedLocalAIModel(for: .llm)
        let embedding = settings.selectedLocalAIModel(for: .embedding)
        #expect(settings.configuredLocalAIModelNames.contains(chat.displayName))
        #expect(settings.configuredLocalAIModelNames.contains(embedding.displayName))
        #expect(!settings.configuredLocalAIModelNames.contains("fallback-chat"))
        #expect(!settings.configuredLocalAIModelNames.contains("fallback-embedding"))
    }
}
