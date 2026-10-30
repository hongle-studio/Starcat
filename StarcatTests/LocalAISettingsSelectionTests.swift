//
//  LocalAISettingsSelectionTests.swift
//  StarcatTests
//
//  回归验证 toolbar 只展示当前会进 MLX 的模型槽，并标出对应业务，而不是设置页
//  当前服务商或固定三类目录。全部使用临时偏好域和安装元数据，不访问真实模型
//  目录，也不触发 MLX 加载。
//

import Foundation
import SwiftUI
import Testing

@testable import Starcat

/// 设置页和状态面板必须复用同一解析结果，关闭页面或重启不能丢失明确选择。
@Suite("LocalAISettingsSelection")
@MainActor
struct LocalAISettingsSelectionTests {
    @Test("三类标签使用完整的本地化键而非插值格式键", arguments: LocalAIModelType.allCases)
    func modelTypeUsesExactLocalizationKey(type: LocalAIModelType) {
        // 先构造普通 String，避免测试期望值也走到相同的 LocalizedStringKey 插值错误。
        let key = "settings.localai.model.type." + type.rawValue
        #expect(LocalAIStatusSection.modelTypeLabelKey(type) == LocalizedStringKey(key))
    }

    @Test("三类标签在产物中均有中英文翻译", arguments: ["en", "zh-Hans"])
    func modelTypeTranslationsExist(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let expected = language == "en" ? ["Embedding", "Reranker", "Generation"] : ["向量化", "重排序", "生成"]
        // 直接读目标语言资源，不改用户语言偏好，也不启动或操作任何应用界面。
        for (type, label) in zip(LocalAIModelType.allCases, expected) {
            let key = "settings.localai.model.type." + type.rawValue
            #expect(bundle.localizedString(forKey: key, value: nil, table: "Localizable") == label)
        }
    }

    @Test("业务标识使用完整的本地化键而非插值格式键")
    func usageUsesExactLocalizationKey() {
        let keys: [(LocalAIStatusUsage, String)] = [
            (.task(.summary), "ai.task.summary"),
            (.task(.tags), "ai.task.tags"),
            (.task(.chat), "ai.task.chat"),
            (.task(.embedding), "ai.task.embedding"),
            (.task(.translation), "ai.task.translation"),
            (.rerank, "rag.workspace.rerank.title"),
        ]
        for (usage, key) in keys {
            #expect(LocalAIStatusSection.usageLabelKey(usage) == LocalizedStringKey(key))
        }
    }

    @Test("下载了多个生成模型时仍只展示当前选中项")
    func onlyShowsSelectedModels() {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            settings.aiChatTask.providerID = LocalAIModelCatalog.builtInProfileID
            settings.aiSettingsSelectedProfileID = "api"
            let selected = LocalAIModelCatalog.entries(of: .llm).last!
            settings.localAIModelSelections[LocalAIModelType.llm.rawValue] = selected.id
            let installed = LocalAIModelCatalog.entries.map(installedModel)
            #expect(installed.count > 3)
            let displayed = settings.localAIStatusModels(installedModels: installed)
            #expect(displayed.map(\.entry.id) == [selected.id])
            #expect(displayed.map(\.entry.type) == [.llm])
            #expect(displayed.first?.usages == [.task(.chat)])
        }
    }

    @Test(
        "设置页正在编辑远程服务商时，任一任务指向 Local AI 仍展示对应槽",
        arguments: [AIModelTask.chat, .summary, .tags, .embedding, .translation]
    )
    func showsWhenAnyTaskUsesLocalAIDespiteRemotePicker(task: AIModelTask) {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            assignTask(settings, task, to: LocalAIModelCatalog.builtInProfileID)
            settings.aiSettingsSelectedProfileID = "api"
            let displayed = statusModels(settings)
            #expect(displayed.count == 1)
            if task == .embedding {
                #expect(displayed[0].entry.type == .embedding)
            } else {
                #expect(displayed[0].entry.type == .llm)
            }
            #expect(displayed[0].usages == [.task(task)])
        }
    }

    @Test("多个生成类任务共用一行，并列出实际业务")
    func generationRowListsBoundTasks() {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            settings.aiSummaryTask.providerID = LocalAIModelCatalog.builtInProfileID
            settings.aiChatTask.providerID = LocalAIModelCatalog.builtInProfileID
            let displayed = statusModels(settings)
            #expect(displayed.map(\.entry.type) == [.llm])
            #expect(displayed[0].usages == [.task(.summary), .task(.chat)])
        }
    }

    @Test("所有任务都指向远程且未开启本地 Rerank 时不展示")
    func hidesWhenNoTaskUsesLocalAI() {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            settings.aiSettingsSelectedProfileID = LocalAIModelCatalog.builtInProfileID
            #expect(statusModels(settings).isEmpty)
        }
    }

    @Test("任务指向已删除的服务商时不展示")
    func hidesWhenTaskProviderIsMissing() {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "removed-profile")
            settings.aiSettingsSelectedProfileID = LocalAIModelCatalog.builtInProfileID
            #expect(statusModels(settings).isEmpty)
        }
    }

    @Test("知识库工作台选中本地对话模型不会单独展示生成行")
    func hidesGenerationWhenOnlyRAGWorkspaceSelectsLocalChat() {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            configureInstalledModels(settings)
            let chat = settings.aiProviderProfiles[0].models.first {
                $0.capability != .embedding && $0.capability != .rerank
            }
            settings.ragWorkspaceSelectedModelID = chat?.id ?? ""
            settings.aiSettingsSelectedProfileID = LocalAIModelCatalog.builtInProfileID
            #expect(statusModels(settings).isEmpty)
        }
    }

    @Test("仅开启本地 Rerank 时只展示重排序行")
    func showsRerankerOnlyWhenLocalRerankEnabled() {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            settings.ragRerankConfiguration = RAGRerankConfiguration(isEnabled: true, provider: .localMLX)
            let displayed = statusModels(settings)
            #expect(displayed.map(\.entry.type) == [.reranker])
            #expect(displayed[0].usages == [.rerank])
        }
    }

    @Test("远程 Rerank 即使开启也不展示重排序行")
    func hidesRerankerForRemoteProvider() {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            settings.ragRerankConfiguration = RAGRerankConfiguration(isEnabled: true, provider: .huggingFaceTEI)
            #expect(statusModels(settings).isEmpty)
        }
    }

    @Test("向量化、Rerank 与生成按槽位顺序排列")
    func ordersConsumedSlots() {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            settings.aiEmbeddingTask.providerID = LocalAIModelCatalog.builtInProfileID
            settings.aiChatTask.providerID = LocalAIModelCatalog.builtInProfileID
            settings.ragRerankConfiguration = RAGRerankConfiguration(isEnabled: true, provider: .localMLX)
            #expect(statusModels(settings).map(\.entry.type) == [.embedding, .reranker, .llm])
        }
    }

    @Test("未下载的选中项不会被其它已下载模型替代")
    func keepsUndownloadedSelection() {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            settings.aiChatTask.providerID = LocalAIModelCatalog.builtInProfileID
            let selected = LocalAIModelCatalog.entries(of: .llm).last!
            let downloaded = LocalAIModelCatalog.entries(of: .llm)[0]
            settings.localAIModelSelections[LocalAIModelType.llm.rawValue] = selected.id
            let models = settings.localAIStatusModels(installedModels: [installedModel(downloaded)])
            #expect(models.last?.entry.id == selected.id)
            #expect(models.count == 1)
        }
    }

    @Test("服务商与三类模型选择跨 AppSettings 重建保留")
    func persistsSelections() {
        withSettings { settings, defaults in
            settings.aiSettingsSelectedProfileID = "api"
            settings.localAIModelSelections = [
                "embedding": LocalAIModelCatalog.entries(of: .embedding).last!.id,
                "reranker": LocalAIModelCatalog.entries(of: .reranker).last!.id,
                "llm": LocalAIModelCatalog.entries(of: .llm).last!.id,
            ]
            let restored = AppSettings(defaults: defaults)
            #expect(restored.localAIModelSelections == settings.localAIModelSelections)
            #expect(restored.aiSettingsSelectedProfileID == "api")
            // 沿用旧 @AppStorage key，不让升级后的设置页突然换回默认服务商。
            #expect(defaults.string(forKey: "settings.ai.lastSelectedProfileID") == "api")
        }
    }

    @Test("空选择使用设置页相同的默认模型", arguments: LocalAIModelType.allCases)
    func sharesDefaultSelection(type: LocalAIModelType) {
        withSettings { settings, _ in
            assignAllTasks(settings, to: "api")
            switch type {
            case .llm:
                settings.aiChatTask.providerID = LocalAIModelCatalog.builtInProfileID
            case .embedding:
                settings.aiEmbeddingTask.providerID = LocalAIModelCatalog.builtInProfileID
            case .reranker:
                settings.ragRerankConfiguration = RAGRerankConfiguration(isEnabled: true, provider: .localMLX)
            }
            settings.aiSettingsSelectedProfileID = ""
            let downloaded = LocalAIModelCatalog.entries(of: type).last!
            let installed = [installedModel(downloaded)]
            let settingSelection = settings.selectedLocalAIModel(for: type, installedModels: installed)
            let statusSelection = settings.localAIStatusModels(installedModels: installed).first { $0.entry.type == type }
            #expect(settingSelection.id == downloaded.id)
            #expect(statusSelection?.entry.id == settingSelection.id)
        }
    }

    @Test("错误类别的 ID 不会让同一类显示另一类模型")
    func rejectsWrongCategory() {
        withSettings { settings, _ in
            settings.localAIModelSelections["embedding"] = LocalAIModelCatalog.reranker.id
            let embedding = settings.selectedLocalAIModel(for: .embedding, installedModels: [])
            #expect(embedding.type == .embedding)
            #expect(embedding.recommended)
        }
    }

    @Test("本地默认选择不改写任务中保存的远程配置")
    func preservesPersistedTaskConfiguration() {
        withSettings { settings, _ in
            let tasks = [settings.aiChatTask, settings.aiSummaryTask, settings.aiTranslationTask, settings.aiEmbeddingTask]
            settings.aiSettingsSelectedProfileID = "api"
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.entries(of: .llm).last!.id
            #expect([settings.aiChatTask, settings.aiSummaryTask, settings.aiTranslationTask, settings.aiEmbeddingTask] == tasks)
        }
    }

    @Test("普通生成任务统一使用 MiniCPM，旧任务中的 Qwen3 不再决定请求")
    func generationTasksUseSelectedLocalModel() throws {
        try withSettings { settings, _ in
            configureInstalledModels(settings)
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.llmMiniCPM5.id
            let tasks = [settings.aiSummaryTask, settings.aiTagsTask, settings.aiChatTask, settings.aiTranslationTask]
            for original in tasks {
                var task = original
                task.providerID = LocalAIModelCatalog.builtInProfileID
                task.modelID = LocalAIModelCatalog.llm.displayName
                task.useCustomModel = false
                let resolved = settings.resolvedAITask(task)
                #expect(resolved.resolvedModelName == LocalAIModelCatalog.llmMiniCPM5.displayName)
                #expect(resolved.parameters.temperature == 1.0)
                #expect(resolved.prompt == original.prompt)
                let selection = try settings.resolveChatSelection(for: task)
                #expect(selection.modelName == resolved.resolvedModelName)
            }
        }
    }

    @Test("请求快照在切换模型和修改参数后保持不变")
    func freezesModelAndParameters() {
        withSettings { settings, _ in
            configureInstalledModels(settings)
            var task = settings.aiSummaryTask
            task.providerID = LocalAIModelCatalog.builtInProfileID
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.llmMiniCPM5.id
            let snapshot = settings.resolvedAITask(task)
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.llm.id
            settings.aiProviderProfiles[0].models[0].parameters = .tagsDefault
            #expect(snapshot.resolvedModelName == LocalAIModelCatalog.llmMiniCPM5.displayName)
            #expect(snapshot.parameters.temperature == 1.0)
            #expect(settings.resolvedAITask(task).resolvedModelName == LocalAIModelCatalog.llm.displayName)
        }
    }

    @Test("摘要缓存键与入口可用性使用当前本地选择")
    func cacheAndAvailabilityUseSelectedModel() throws {
        try withSettings { settings, _ in
            configureInstalledModels(settings)
            settings.aiSummaryTask.providerID = LocalAIModelCatalog.builtInProfileID
            settings.aiChatTask.providerID = LocalAIModelCatalog.builtInProfileID
            settings.aiSummaryTask.modelID = "stale-summary-model"
            settings.aiChatTask.modelID = "stale-chat-model"
            let database = try InMemoryDatabaseManager()
            let service = RepoAIInsightService(
                summaryRepository: GRDBAISummaryRepository(database: database),
                readmeRepository: ReadmeRepository(database: database),
                settings: settings, keychain: InMemoryKeychain())
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.llmMiniCPM5.id
            let miniKey = service.cacheModelKey()
            #expect(settings.hasConfiguredChatModel)
            #expect(miniKey.contains("summary:\(LocalAIModelCatalog.builtInProfileID)/\(LocalAIModelCatalog.llmMiniCPM5.displayName)"))
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.llm.id
            #expect(service.cacheModelKey() != miniKey)
            #expect(!service.cacheModelKey().contains("stale-summary-model"))
        }
    }

    @Test("明确选择未安装模型时失败，不回退其它权重")
    func doesNotFallbackToInstalledLLM() throws {
        try withSettings { settings, _ in
            configureInstalledModels(settings, entries: [LocalAIModelCatalog.llm])
            var task = settings.aiSummaryTask
            task.providerID = LocalAIModelCatalog.builtInProfileID
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.llmMiniCPM5.id
            #expect(settings.resolvedAITask(task).modelID == LocalAIModelCatalog.llmMiniCPM5.displayName)
            #expect(throws: AIChatSelectionError.self) { try settings.resolveChatSelection(for: task) }
        }
    }

    @Test("向量化选择独立于生成，卸载保留集合与实际模型一致")
    func embeddingAndResidencyFollowSelections() throws {
        try withSettings { settings, _ in
            configureInstalledModels(settings)
            let embedding = LocalAIModelCatalog.entries(of: .embedding).last!
            settings.aiEmbeddingTask.providerID = LocalAIModelCatalog.builtInProfileID
            settings.aiSummaryTask.providerID = LocalAIModelCatalog.builtInProfileID
            settings.localAIModelSelections = ["embedding": embedding.id, "llm": LocalAIModelCatalog.llmMiniCPM5.id]
            let selection = try settings.resolveEmbeddingSelection()
            #expect(selection.modelName == embedding.displayName)
            #expect(settings.configuredLocalAIModelNames.contains(embedding.displayName))
            #expect(settings.configuredLocalAIModelNames.contains(LocalAIModelCatalog.llmMiniCPM5.displayName))
            #expect(!settings.configuredLocalAIModelNames.contains(LocalAIModelCatalog.llm.displayName))
        }
    }

    @Test("API 任务的模型和参数不被本地选择覆盖")
    func remoteTaskIsUnchanged() {
        withSettings { settings, _ in
            var task = settings.aiSummaryTask
            task.providerID = "api"
            task.modelID = "remote-model"
            task.useCustomModel = false
            task.parameters.temperature = 0.31
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.llmMiniCPM5.id
            #expect(settings.resolvedAITask(task) == task)
        }
    }

    @Test("同步模型目录保留参数覆盖与禁用状态，并移除已删除模型")
    func preservesModelOverridesOnSync() throws {
        let entry = LocalAIModelCatalog.llmMiniCPM5
        let previous = AIModelDescriptor(
            providerID: LocalAIModelCatalog.builtInProfileID, name: entry.displayName,
            capability: .chat, isEnabled: false, parameters: .translationDefault)
        let models = LocalAIModelManager.installedModelDescriptors(
            installedModels: [installedModel(entry)], previousModels: [previous])
        let model = try #require(models.first)
        #expect(model.parameters == previous.parameters)
        #expect(!model.isEnabled)
        #expect(LocalAIModelManager.installedModelDescriptors(installedModels: [], previousModels: models).isEmpty)
    }

    @Test("本地重排序使用所选目录而非固定 4bit 模型")
    func rerankerUsesSelectedModel() {
        let entry = LocalAIModelCatalog.entries(of: .reranker).last!
        let reranker = LocalMLXRAGReranker(configuration: .init(), model: entry)
        #expect(reranker.debugModel == entry.displayName)
    }

    @Test("Agent 在加载或读取凭据前拒绝不支持工具调用的本地模型")
    func agentRejectsLocalToolCalling() throws {
        try withSettings { settings, _ in
            configureInstalledModels(settings)
            settings.aiChatTask.providerID = LocalAIModelCatalog.builtInProfileID
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.llmMiniCPM5.id
            #expect(throws: AgentLoopModelError.self) { try AgentLoopModelClientFactory.make(settings: settings) }
        }
    }

    /// 五类任务一次性改 provider，避免首启动 Local AI 默认覆盖掩盖门控。
    private func assignAllTasks(_ settings: AppSettings, to providerID: String) {
        for task in AIModelTask.allCases {
            assignTask(settings, task, to: providerID)
        }
    }

    private func assignTask(_ settings: AppSettings, _ task: AIModelTask, to providerID: String) {
        switch task {
        case .chat: settings.aiChatTask.providerID = providerID
        case .summary: settings.aiSummaryTask.providerID = providerID
        case .tags: settings.aiTagsTask.providerID = providerID
        case .embedding: settings.aiEmbeddingTask.providerID = providerID
        case .translation: settings.aiTranslationTask.providerID = providerID
        }
    }

    private func statusModels(_ settings: AppSettings) -> [LocalAIStatusModel] {
        settings.localAIStatusModels(installedModels: LocalAIModelCatalog.entries.map(installedModel))
    }

    /// 只提供已验证安装目录的描述；所有解析测试不执行磁盘扫描或模型加载。
    private func configureInstalledModels(_ settings: AppSettings, entries: [LocalAIModelCatalogEntry] = LocalAIModelCatalog.entries) {
        settings.aiProviderProfiles[0].models = entries.map {
            AIModelDescriptor(providerID: LocalAIModelCatalog.builtInProfileID, name: $0.displayName, capability: $0.capability)
        }
        settings.aiProviderProfiles[0].lastTestStatus = .success(modelCount: entries.count)
    }

    /// 每个用例独立持久化域，避免碰到用户正在使用的服务商配置。
    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) rethrows {
        let suite = "LocalAISettingsSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.aiProviderProfiles = [
            AIProviderProfile(id: LocalAIModelCatalog.builtInProfileID, provider: .localAI, models: [], lastTestStatus: .notTested),
            AIProviderProfile(id: "api", provider: .openAICompatible, models: [], lastTestStatus: .notTested),
        ]
        settings.aiSettingsSelectedProfileID = LocalAIModelCatalog.builtInProfileID
        try body(settings, defaults)
    }

    /// 安装清单夹具只提供身份信息，真实文件与内存状态都不参与选择解析。
    private func installedModel(_ entry: LocalAIModelCatalogEntry) -> LocalAIInstalledModel {
        LocalAIInstalledModel(
            id: entry.id, displayName: entry.displayName, type: entry.type, revision: "test",
            installedAt: Date(), sourceKind: .huggingFace, files: [],
            embeddingDimension: entry.embeddingDimension, totalBytes: 0)
    }
}
