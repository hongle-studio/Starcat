//
//  AISettingsView.swift
//  Starcat
//
//  AI 服务配置面板。
//
//  模块级说明：
//  - 本页面实现多服务商 BYOK：用户可以同时配置 OpenAI、DeepSeek、OpenRouter、
//    Ollama、LM Studio 或任意 OpenAI-compatible 服务。
//  - API Key 按 provider profile ID 写入 `KeychainManager` 管理的本地加密文件；
//    provider / 模型启用状态 / 参数 / Prompt 写入 `AppSettings`。
//  - 摘要、推荐标签、Embedding 三类任务独立选择 provider 与模型，满足“摘要走本地，
//    Embedding 走远端”这类组合。
//
//  关键约束：
//  - 不把 API Key 存入 UserDefaults，也不打印到日志。
//  - 模型列表接口只强依赖 `id` 字段，能力用启发式推断并允许用户手动修正。
//  - `topK` 当前仅保存配置，不发送到标准 OpenAI Chat Completions，原因见详细设计文档。
//

import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// 主设置中的 AI 分类页。
///
/// 四个页面只重新组织既有配置，不复制 `AppSettings` 状态：模型是所有 AI 能力的
/// 上游依赖，自动化消费模型配置，索引与上下文承载本地数据准备，外部搜索独立配置。
enum AISettingsPage: Hashable {
    case models
    case automation
    case indexAndContext
    case externalSearch
}

/// AI 设置分类页面。
struct AISettingsTab: View {

    let page: AISettingsPage

    @Environment(AppSettings.self) private var settings
    /// HOM-126：「立刻手动触发一次」按钮直接调度。@Environment 注入自 StarcatApp。
    @Environment(AutoTidyScheduler.self) private var autoTidyScheduler
    /// 2026-06-12 向量索引改进：AI 索引 Section 的"开始 / 暂停 / 全量重建"按钮需要
    /// 直接调度 `SemanticIndexBuilder`。从 AppDependencies 拿。
    @Environment(AppDependencies.self) private var dependencies
    /// disclosureLabel 与草稿 Provider 收放等动画在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// 2026-06-16:`RelativeDateTimeFormatter` 默认走系统 locale,需显式注入跟随
    /// LocaleStore 切换。Settings scene 已挂 `appLocaleEnvironment()`。
    @Environment(\.locale) private var locale

    /// HOM-AIPROVIDERS-PERSIST-2026-06-06 (dong4j 反馈)：
    /// 之前用 `@State private var selectedProfileID: String?` 保存当前选中的服务商
    /// profile，关掉 Settings 窗口再打开就会被 SwiftUI 销毁重建，`selectedProfileID`
    /// 重置为 nil，`ensureSelection()` 强制把它落回 `verifiedProfiles.first`。
    /// 多 profile 场景（DeepSeek + OpenAI 都已验证、用户最后选的是 OpenAI）下，
    /// 用户每次进入 AI 设置都会被强行切回 DeepSeek（第一个），第二行 Provider
    /// picker 也跟着回到 DeepSeek，违反"进页面时显示当前选中的已配好服务商"诉求。
    ///
    /// 选择现在由 AppSettings 共用并持久化，沿用原 key 与空串 nil 哨兵，
    /// 让 toolbar 同步知道设置页当前查看的服务商。`ensureSelection()` 保留兜底逻辑：
    /// 持久化的 ID 在当前已验证列表里找不到（profile 被删 / 升级后改了 ID）时
    /// 降级到 `verifiedProfiles.first?.id`，避免"指向幽灵 profile"。
    /// 当前选中的服务商 profile ID。空串持久化值视为 nil。
    /// 真正的写入入口走 `setSelectedProfileID(_:)`，避免散落的赋值绕过空串哨兵。
    private var selectedProfileID: String? {
        settings.aiSettingsSelectedProfileID.isEmpty ? nil : settings.aiSettingsSelectedProfileID
    }

    @State private var apiKeys: [String: String] = [:]
    @State private var isTestingProfileID: String?
    /// 新增和编辑复用同一草稿弹窗；父窗口关闭时同步取消，防止迟到请求写回。
    @State private var providerSetupSession: AIProviderSetupViewModel?
    /// 编辑入口捕获当前任务，弹窗始终写回该任务，不与另一个分段选择器争用状态。
    @State private var promptEditingTask: AIModelTask?
    @State private var isTaskModelAdvancedExpanded = false
    @State private var isEmbeddingAdvancedExpanded = false
    @State private var isModelManagementAdvancedExpanded = false
    /// 只管理页面展示，不持久化，也不因折叠或关闭总开关重置用户的自动化配置。
    @State private var isTagPolicyExpanded = false
    @State private var isAutoTidyRulesExpanded = false
    @State private var isListGroupingRulesExpanded = false
    /// 捕获打开时的服务商身份；弹窗按 ID 读取实时模型，不使用这份快照编辑数据。
    @State private var modelManagementProfile: AIProviderProfile?

    /// HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12 (dong4j 反馈)：
    /// 删除服务商需要二次确认。删除会同步删 profile + Keychain key + 修复
    /// 任务绑定（`repairTasksAfterProfileChange`），属于不可逆破坏性操作，
    /// 走 `.confirmationDialog` 拦一道。`pendingDeleteProfileID` 持有待删
    /// 目标的 ID 而非整个 profile，避免 dialog 弹起期间 `verifiedProfiles`
    /// 数组变化导致引用悬空（异步刷新 / @AppStorage 写回都可能触发刷新）。
    @State private var pendingDeleteProfileID: String?

    /// 这里只切换生成任务；共享向量模型独立展示，仍写入原 aiEmbeddingTask。
    @State private var taskModelTask: AIModelTask = .summary

    /// 跨服务商同名模型必须保留复合身份，自定义项只呈现现有配置，不触发额外写入。
    private typealias TaskModelChoice = AITaskModelPicker.Selection

    // HOM-68 follow-up v9：原"模型参数"区已迁到"已发现模型"每行的齿轮 popover
    // （模型粒度，不再按任务），不再需要 isParametersExpanded SceneStorage。
    private static let taskModelsSettingsAnchor = "settings.ai.taskModels"
    private static let embeddingSettingsAnchor = "settings.ai.sharedEmbedding"
    private static let aiIndexSettingsAnchor = "settings.ai.index"

    /// "AI 索引"折叠区显示 / 隐藏具体阈值数字；预设 == `.custom` 时强制展开（写 didSet 上不易，
    /// 这里通过 computed `effectiveAdvancedExpanded` 处理）。
    @SceneStorage("settings.ai.aiIndex.advancedExpanded") private var isAIIndexAdvancedExpanded: Bool = false

    private static let repoContextSettingsAnchor = "settings.ai.repoContext"
    private static let externalSearchSettingsAnchor = "settings.ai.externalSearch"

    /// HOM-68 v3 (2026-06-15)：AI 代码上下文产物管理面板从存储 Tab 搬过来。
    /// `@Observable` 单例直接订阅；视图层调 reveal / delete 等方法时由 storage 内部
    /// 处理 security scope。
    @State private var aiContextStorage = RepoContextStorage.shared

    /// AI 代码上下文 storage 操作失败时弹 alert 用，独立于服务商弹窗的验证错误。
    @State private var aiContextActionError: String?

    /// "全量重建"二次确认。
    @State private var pendingRebuildAllConfirm: Bool = false
    /// 免费用户点击 AI 设置页升级入口时展示统一 Pro 付费墙。
    @State private var paywallContext: ProPaywallContext?
    /// CC Switch 导入预览。确认前不写 Keychain。
    @State private var ccSwitchImportSession: CCSwitchImportSession?
    @State private var ccSwitchImportError: String?

    init(page: AISettingsPage = .models) {
        self.page = page
    }

    /// 模型、自动化与语义索引继续遵守既有 Pro / Apple Silicon Local AI 门控；
    /// 免费的联网搜索和仓库上下文不使用此配置权限。
    private var hasAIConfigurationAccess: Bool {
        dependencies.entitlementGate.isProUser || LocalAIHardwareSupport.isLocalAIAvailable
    }

    @ViewBuilder
    var body: some View {
        // AI 服务是 Direct / StoreKit 共享的 Pro 能力，必须读取聚合后的业务门控；
        // 直接读取 SubscriptionManager 会把 Direct License 用户误判为未开通。
        // 本地 AI 免费（dong4j 2026-09-12）：Apple Silicon 上免费用户也必须能进入
        // 本页配置并下载本地模型；远程 provider 的消费仍由 EntitlementGate 在调用点拦截，
        // 设置页只是配置面。仓库上下文已免费，因此 Intel 免费用户也能进入其所在页。
        if page == .externalSearch || page == .indexAndContext || hasAIConfigurationAccess {
            aiConfigurationForm
        } else {
            lockedAISettings
        }
    }

    private var aiConfigurationForm: some View {
        ScrollViewReader { proxy in
        // HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
        // 删除独立的"模型参数"区。原因：参数与"任务"绑定有歧义——同一模型被
        // 摘要 / 标签 / 翻译复用时，按任务调参数会出现"在'模型参数 → 摘要'调
        // temperature 只对'用 X 模型的摘要任务'生效，其它任务用 X 模型还是默认值"
        // 的反直觉行为。改成每行模型一个齿轮按钮 + popover，参数与"模型"绑定。
        Form {
            switch page {
            case .models:
                modelsIntroductionSection
                providerSection
                // 本地模型只在选中 Starcat Local AI 时出现，避免远程供应商页面
                // 同时展示无关下载项；模型与任务绑定按依赖顺序从上到下排列。
                if LocalAIHardwareSupport.isLocalAIAvailable, activeProfile?.provider == .localAI {
                    LocalAIModelsSection(settings: dependencies.settings)
                }
                taskModelsSection
                    .id(Self.taskModelsSettingsAnchor)
                sharedEmbeddingSection
                    .id(Self.embeddingSettingsAnchor)
                modelManagementAdvancedSection
            case .automation:
                // 两项都消费上游模型配置，但彼此不是父子能力，保留独立顶级 Section。
                automationIntroductionSection
                autoTidySection
                githubListGroupingSection
                automationModelsSection
            case .indexAndContext:
                // 仅开放上下文配置；语义索引仍沿用原 Pro / 本地 AI 条件。
                if hasAIConfigurationAccess {
                    aiIndexSection
                        .id(Self.aiIndexSettingsAnchor)
                }
                aiRepoContextSection
                    .id(Self.repoContextSettingsAnchor)
            case .externalSearch:
                // 联网搜索原本对所有用户可配置，因此独立页面不能被 AI Pro 门控隐藏。
                ExternalSearchSettingsSection()
                    .id(Self.externalSearchSettingsAnchor)
            }
        }
        .alert(
            "settings.aiIndex.rebuildAll.confirmTitle",
            isPresented: $pendingRebuildAllConfirm
        ) {
            Button("settings.aiIndex.rebuildAll.confirm", role: .destructive) {
                dependencies.semanticIndexBuilder.rebuildAll()
            }
            Button("general.cancel", role: .cancel) {}
        } message: {
            Text("settings.aiIndex.rebuildAll.confirmMessage")
        }
        .alert(
            "settings.ai.provider.importCCSwitch",
            isPresented: Binding(
                get: { ccSwitchImportError != nil },
                set: { if !$0 { ccSwitchImportError = nil } }
            )
        ) {
            Button("general.cancel", role: .cancel) {}
        } message: {
            Text(ccSwitchImportError ?? "")
        }
        .sheet(item: $ccSwitchImportSession) { session in
            CCSwitchImportPreviewSheet(
                preview: session.preview,
                onImport: { candidates, progress in
                    await importCCSwitchCandidates(candidates, progress: progress)
                },
                onSelectProfile: { profileID in
                    setSelectedProfileID(profileID)
                }
            )
        }
        .sheet(item: providerSetupPresentation) { session in
            AIProviderSetupSheet(viewModel: session, onAdd: saveVerifiedProvider)
                .id(session.id)
                .appLocaleEnvironment()
        }
        .sheet(item: $promptEditingTask) { task in
            AITaskPromptSheet(
                task: task,
                systemPrompt: promptSystemBinding(task),
                userPromptTemplate: promptUserBinding(task),
                onRestoreDefault: { restoreDefaultPrompt(task) }
            )
            .appLocaleEnvironment()
        }
        .sheet(item: $modelManagementProfile) { profile in
            AIModelManagementSheet(
                providerID: profile.id,
                enabledBinding: { model in modelEnabledBinding(profile.id, model.id) },
                capabilityBinding: { model in modelCapabilityBinding(profile.id, model.id) },
                parametersBinding: { model in modelParametersBinding(profile.id, model.id) }
            )
            .appLocaleEnvironment()
        }
        .formStyle(.grouped)
        .task(id: page) {
            guard page == .models else { return }
            ensureSelection()
            loadAPIKeys()
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToAIRepoContextSection)) { _ in
            guard page == .indexAndContext else { return }
            // Settings 首次创建时 Form 的滚动容器要到下一轮 RunLoop 才完成布局。
            DispatchQueue.main.async {
                proxy.scrollTo(Self.repoContextSettingsAnchor, anchor: .top)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToAIIndexSection)) { _ in
            guard page == .indexAndContext else { return }
            DispatchQueue.main.async {
                proxy.scrollTo(Self.aiIndexSettingsAnchor, anchor: .top)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToAIEmbeddingSection)) { _ in
            guard page == .models else { return }
            // 向量模型已独立分组；深链直接定位，不改变生成任务的当前选择。
            DispatchQueue.main.async {
                proxy.scrollTo(Self.embeddingSettingsAnchor, anchor: .top)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToAIChatModelSection)) { _ in
            guard page == .models else { return }
            // 从工作台缺少模型提示进入时，直接选中“对话”并定位常驻分组。
            taskModelTask = .chat
            DispatchQueue.main.async {
                proxy.scrollTo(Self.taskModelsSettingsAnchor, anchor: .top)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToSettingsTab)) { note in
            guard page == .externalSearch,
                  let target = note.object as? String,
                  target == "integrations.externalSearch" || target == "ai.externalSearch" else { return }
            DispatchQueue.main.async {
                proxy.scrollTo(Self.externalSearchSettingsAnchor, anchor: .top)
            }
        }
        // 只监听所属设置窗口；关闭时同步失效会话，防止网络回调在退场动画期间保存。
        .background(SettingsWindowCloseListener {
            providerSetupSession?.cancel()
            providerSetupSession = nil
        })
        // HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12 (dong4j 反馈)：
        // 删除服务商二次确认。用 `presenting:` 把 profile 注入到 alert 闭包，
        // 让按钮标题能显示具体服务商名（"删除「DeepSeek」"），减少误删风险。
        // 用 `pendingDeleteProfileID` 而非整个 profile 作为状态源，避免数组刷新
        // 期间引用悬空（见 `pendingDeleteProfileID` 注释）。
        .alert(
            "settings.ai.provider.deleteConfirm.title",
            isPresented: deleteConfirmationBinding,
            presenting: pendingDeleteProfile
        ) { profile in
            Button(role: .destructive) {
                deleteProfile(id: profile.id)
            } label: {
                Text(String(format: String.l10n("settings.ai.provider.deleteConfirm.confirmFormat"), profile.displayName))
            }
            Button("settings.common.cancel", role: .cancel) {
                pendingDeleteProfileID = nil
            }
        } message: { profile in
            Text(String(format: String.l10n("settings.ai.provider.deleteConfirm.messageFormat"), profile.displayName))
        }
        // HOM-68 v3 (2026-06-15)：AI 代码上下文产物管理从存储 Tab 搬过来后,
        // 进入 AI Tab 时强制重扫描产物目录,让用户刚生成的产物立即可见。
        .task(id: page) {
            guard page == .indexAndContext else { return }
            aiContextStorage.reload()
        }
        // AI 代码上下文 storage 操作失败 alert (与 IntegrationSettingsView 同款模式)。
        .alert(
            "ai.context.storage.actionFailed",
            isPresented: Binding(
                get: { aiContextActionError != nil },
                set: { if !$0 { aiContextActionError = nil } }
            )
        ) {
            Button("general.ok") { aiContextActionError = nil }
        } message: {
            Text(aiContextActionError ?? "")
        }
        }
    }

    private var lockedAISettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        ProCrownIcon(size: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("settings.ai.locked.title")
                                .font(.title3.weight(.semibold))
                            Text("settings.ai.locked.subtitle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("settings.ai.locked.benefit.byok", systemImage: "key.fill")
                        Label("settings.ai.locked.benefit.workflow", systemImage: "sparkles")
                        Label("settings.ai.locked.benefit.billing", systemImage: "creditcard")
                    }
                    .font(.callout)

                    Button {
                        paywallContext = ProPaywallContext(
                            feature: .aiSummary,
                            message: String.l10n("settings.ai.locked.paywallMessage")
                        )
                    } label: {
                        Label("settings.ai.locked.upgrade", systemImage: "crown.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("settings.ai.locked.footer")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
    }

    /// 二次确认 dialog 的 isPresented 绑定。
    /// set 时支持外部把它置 false（点 macOS 系统返回 / 点空白处关 dialog），
    /// 同步清掉 `pendingDeleteProfileID` 避免下次再弹时残留旧目标。
    private var deleteConfirmationBinding: Binding<Bool> {
        return Binding(
            get: { pendingDeleteProfileID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteProfileID = nil
                }
            }
        )
    }

    /// 当前待删除目标的 profile。pendingDeleteProfileID 持有 ID 而非整个 profile，
    /// 这里实时查表，避免数组刷新引用悬空。如果 ID 找不到对应 profile（删除瞬间数据
    /// 已变），返回 nil 让 dialog 自然 dismiss（`confirmationDialog(presenting:)` 在
    /// presenting 为 nil 时不展示 content）。
    private var pendingDeleteProfile: AIProviderProfile? {
        guard let id = pendingDeleteProfileID else { return nil }
        return profile(id)
    }

    /// 真删除入口，由 confirmationDialog 内部按钮调用。
    /// 既有的 `deleteSelectedProfile()` 隐式依赖 `selectedProfileID`，但二次确认
    /// 期间用户可能切换了 selection，所以这里收紧到「按显式 ID 删除」，与
    /// pendingDeleteProfileID 的语义一致，避免误删。
    private func deleteProfile(id: String) {
        AppLog.ai.debug("[AISettings] deleteProfile(id:) confirmed id=\(id, privacy: .public)")
        settings.aiProviderProfiles.removeAll { $0.id == id }
        try? KeychainManager.shared.deleteAIKey(forProvider: id)
        apiKeys.removeValue(forKey: id)
        // 被删的恰好是当前 selected 时，回退到剩余 verified 中的第一个；
        // 否则保持当前 selection 不动（删的是非当前项时，用户视线不应被打断）。
        if selectedProfileID == id {
            setSelectedProfileID(pickerProfiles.first?.id)
        }
        repairTasksAfterProfileChange()
        pendingDeleteProfileID = nil
    }

    // MARK: - Provider

    /// 系统主动结束 sheet 时也立即失效会话，不能只依赖退场动画后的 onDisappear。
    private var providerSetupPresentation: Binding<AIProviderSetupViewModel?> {
        Binding(
            get: { providerSetupSession },
            set: { session in
                if session == nil { providerSetupSession?.cancel() }
                providerSetupSession = session
            }
        )
    }

    /// 与通用和隐私页保持同一说明卡片结构，使用 Form 自带表面，不再套第二层背景。
    private var modelsIntroductionSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "cpu")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.models.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text("settings.models.title"))
                    Text("settings.models.introduction")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text("settings.models.introduction"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    /// 验证器没有写入副作用；确认成功且会话仍有效后，才同步保存凭据与配置。
    /// Keychain 先写，失败则抛回弹框，避免未保存密钥的服务商进入任务选择。
    @MainActor
    private func saveVerifiedProvider(_ profile: AIProviderProfile, apiKey: String) throws {
        guard let session = providerSetupSession,
              session.profile.id == profile.id else { throw CancellationError() }
        if session.isEditing {
            // 原位替换，保留服务商 ID 和列表顺序；目标已删除时不能被迟到结果重新创建。
            var profiles = settings.aiProviderProfiles
            guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
                throw CancellationError()
            }
            try persistAPIKey(apiKey, forProvider: profile.id, allowsEmpty: profile.provider.allowsEmptyAPIKey)
            profiles[index] = profile
            settings.aiProviderProfiles = profiles
        } else {
            try persistAPIKey(apiKey, forProvider: profile.id, allowsEmpty: profile.provider.allowsEmptyAPIKey)
            settings.aiProviderProfiles.append(profile)
        }
        apiKeys[profile.id] = apiKey
        setSelectedProfileID(profile.id)
        repairTasksAfterProfileChange()
    }

    /// 捕获当前配置创建编辑草稿，仍走现有模型发现与引用保护；打开窗口不写入配置。
    private func editSelectedProvider() {
        guard let profile = selectedProfile, profile.provider != .localAI else { return }
        providerSetupSession = AIProviderSetupViewModel(
            editingProfile: profile,
            existingAPIKey: apiKeys[profile.id, default: ""],
            verify: { draft, apiKey in
                try await AIProviderConnectionVerifier.verify(
                    profile: draft,
                    apiKey: apiKey,
                    referencedModelNames: referencedModelNames(for: draft.id)
                )
            }
        )
    }

    private var providerSection: some View {
        Section {
            // 配置行只保留选择、修改与新增；低频的导入和删除放在下方模型状态行。
            HStack(alignment: .center, spacing: 8) {
                Text("settings.ai.provider.pickerLabel")
                    .font(.body)
                    .frame(width: 96, alignment: .leading)
                    .lineLimit(1)

                if pickerProfiles.isEmpty {
                    Text("settings.ai.provider.empty")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Spacer(minLength: 8)
                    Picker("settings.ai.provider.pickerLabel", selection: selectedProfileBinding) {
                        ForEach(pickerProfiles) { profile in
                            Label {
                                Text(profile.displayName)
                            } icon: {
                                AIProviderIconView(provider: profile.provider, size: 14)
                            }
                            .tag(Optional(profile.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                if let profile = selectedProfile, profile.provider != .localAI {
                    SettingsActionIconButton(
                        title: "settings.ai.provider.edit.help",
                        systemImage: "pencil"
                    ) {
                        editSelectedProvider()
                    }
                    .disabled(isTestingProfileID != nil || providerSetupSession != nil)
                }

                AddIconButton(help: Text("settings.ai.provider.addHelp")) {
                    providerSetupSession = AIProviderSetupViewModel()
                }
                .disabled(isTestingProfileID != nil || providerSetupSession != nil)
            }

            HStack(spacing: 8) {
                if let profile = selectedProfile {
                    // 数量读取当前目录，不能沿用上次测试的快照；未就绪的本地 AI 不标为已验证。
                    let verified = profile.isVerifiedConfiguration
                    let summary = String(
                        format: String.l10n(verified
                            ? "settings.ai.provider.models.verifiedCountFormat"
                            : "settings.ai.provider.models.countFormat"),
                        profile.models.count.formatted(.number.locale(locale))
                    )
                    Label(summary, systemImage: verified ? "checkmark.circle" : "square.stack.3d.up")
                        .font(.caption)
                        .foregroundStyle(verified ? Color.green : Color.secondary)
                        .lineLimit(1)
                        .help(summary)
                }

                Spacer(minLength: 8)

                ImportIconButton(help: Text("settings.ai.provider.importCCSwitch.help")) {
                    beginCCSwitchImport()
                }
                .disabled(isTestingProfileID != nil || providerSetupSession != nil)

                DestructiveIconButton(
                    help: Text("settings.ai.provider.deleteHelp"),
                    font: SettingsIconMetrics.standardGlyph,
                    frameSize: SettingsIconMetrics.actionFrameSize
                ) {
                    pendingDeleteProfileID = selectedProfileID
                }
                .disabled(selectedProfile == nil || selectedProfile?.provider == .localAI)
            }

            if selectedProfile?.provider == .localAI {
                Text("settings.localai.provider.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            SettingsSectionHeader(
                "settings.models.provider.section",
                systemImage: "server.rack"
            )
        }
    }

    /// 模型列表移至当前服务商的管理弹窗；页面末尾只保留按需展开的入口。
    private var modelManagementAdvancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isModelManagementAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionHeader("settings.ai.models.management.section", systemImage: "slider.horizontal.3")
                    centeredModelSettingRow {
                        Button("settings.ai.models.management.open", systemImage: "list.bullet.rectangle") {
                            // 只确定本次管理对象；编辑仍通过原模型绑定即时写回。
                            modelManagementProfile = selectedProfile
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(selectedProfile == nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.ai.models.management.available")
                                .lineLimit(1)
                                .help(Text("settings.ai.models.management.available"))
                            Text("settings.ai.models.management.help")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .help(Text("settings.ai.models.management.help"))
                        }
                    }
                }
            } label: {
                Text("settings.ai.models.advanced.title")
                    .lineLimit(1)
                    .help(Text("settings.ai.models.advanced.title"))
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.ai.models.advanced.title")
            ))
        }
    }

    // MARK: - Tasks

    /// 三个生成任务共享同一套原生配置行，各自的模型与提示词仍独立保存。
    private var taskModelsSection: some View {
        Section {
            centeredModelSettingRow {
                Picker("settings.ai.task.pickerLabel", selection: $taskModelTask) {
                    ForEach(AIModelTask.aiSettingsPageTasks) { task in
                        Text(LocalizedStringKey(task.displayNameKey)).tag(task)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.task.pickerLabel")
                        .lineLimit(1)
                        .help(Text("settings.ai.task.pickerLabel"))
                    Text("settings.ai.models.task.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.ai.models.task.help"))
                }
            }

            centeredModelSettingRow {
                taskModelPicker(taskModelTask, label: "settings.ai.models.model.title")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.model.title")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.model.title"))
                    Text("settings.ai.models.model.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.ai.models.model.help"))
                }
            }

            centeredModelSettingRow {
                Button("settings.ai.models.prompt.edit", systemImage: "text.quote") {
                    promptEditingTask = taskModelTask
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.prompt.title")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.prompt.title"))
                    Text(LocalizedStringKey(isDefaultPrompt(taskModelTask)
                        ? "settings.ai.models.prompt.default" : "settings.ai.models.prompt.custom"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            DisclosureGroup(isExpanded: $isTaskModelAdvancedExpanded) {
                taskCustomModelConfiguration(taskModelTask)
            } label: {
                Text("settings.ai.task.customModelLabel")
                    .lineLimit(1)
                    .help(Text("settings.ai.task.customModelLabel"))
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.ai.task.customModelLabel")
            ))
        } header: {
            SettingsSectionHeader("settings.ai.models.defaults.title", systemImage: "slider.horizontal.3")
        }
    }

    /// 一个原生菜单汇总已验证服务商的适用模型，保留自定义及暂不可用配置的显示身份。
    private func taskModelPicker(_ task: AIModelTask, label: LocalizedStringKey) -> some View {
        let config = taskConfig(task)
        let profiles = eligibleVerifiedProfiles(for: task)
        let providerName = profile(config.providerID)?.displayName ?? config.providerID

        return AITaskModelPicker(
            title: label,
            profiles: profiles,
            selection: taskModelChoiceBinding(task),
            providerDisplayName: providerName
        ) { provider in
            enabledModels(providerID: provider.id, capability: task.requiredCapability)
        }
    }

    /// 自定义模型继承当前默认模型的服务商；原开关和名称绑定仍保留输入文本。
    private func taskCustomModelConfiguration(_ task: AIModelTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("settings.ai.models.custom.enabled", isOn: taskCustomEnabledBinding(task))
                .toggleStyle(.switch)
                .lineLimit(1)
                .help(Text("settings.ai.models.custom.enabled"))
            if taskConfig(task).useCustomModel {
                LabeledContent {
                    TextField("settings.ai.models.custom.name", text: taskCustomModelBinding(task))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .disableAutocorrection(true)
                } label: {
                    Text("settings.ai.models.custom.name")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.custom.name"))
                }
            }
        }
    }

    /// LabeledContent 默认按首行基线排版；双行说明改用原生 HStack 让整个文本块与控件居中。
    private func centeredModelSettingRow<Content: View, RowLabel: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> RowLabel
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 12)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 语义搜索与知识库检索只保留一个向量模型入口，索引管理仍跳转到各自现有页面。
    private var sharedEmbeddingSection: some View {
        Section {
            centeredModelSettingRow {
                taskModelPicker(.embedding, label: "settings.ai.models.embedding.model")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.embedding.model")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.embedding.model"))
                    Text("settings.ai.models.embedding.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.ai.models.embedding.help"))
                }
            }
            Text("settings.ai.models.embedding.storageHint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("settings.ai.models.embedding.index.title") {
                HStack(spacing: 12) {
                    Button("settings.ai.models.embedding.index.repo") {
                        NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.index")
                    }
                    .help(Text("settings.ai.models.embedding.index.repo"))
                    Button("settings.ai.models.embedding.index.knowledge") {
                        NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "rag.retrieval")
                    }
                    .help(Text("settings.ai.models.embedding.index.knowledge"))
                }
                .buttonStyle(.link)
                .controlSize(.regular)
                .lineLimit(1)
            }

            centeredModelSettingRow {
                Button("settings.ai.models.prompt.edit", systemImage: "text.quote") {
                    promptEditingTask = .embedding
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.embedding.template.title")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.embedding.template.title"))
                    Text("settings.ai.models.embedding.template.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.ai.models.embedding.template.help"))
                }
            }

            DisclosureGroup(isExpanded: $isEmbeddingAdvancedExpanded) {
                taskCustomModelConfiguration(.embedding)
            } label: {
                Text("settings.ai.task.customModelLabel")
                    .lineLimit(1)
                    .help(Text("settings.ai.task.customModelLabel"))
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.ai.task.customModelLabel")
            ))
        } header: {
            SettingsSectionHeader("settings.ai.models.embedding.title", systemImage: "point.3.connected.trianglepath.dotted")
        } footer: {
            Text("settings.ai.models.embedding.footer")
        }
    }

    /// 状态文案只对比当前任务的已存提示词与默认值，不写入或恢复任何配置。
    private func isDefaultPrompt(_ task: AIModelTask) -> Bool {
        let defaults: AIPromptConfiguration
        switch task {
        case .summary: defaults = AIDefaultPrompts.summary
        case .tags: defaults = AIDefaultPrompts.tags
        case .chat: defaults = AIDefaultPrompts.chat
        case .embedding: defaults = AIDefaultPrompts.embedding
        case .translation: defaults = AIDefaultPrompts.translation
        }
        return taskConfig(task).prompt == defaults
    }

    // MARK: - Parameters (已迁移到 AIModelListView 的齿轮 popover)

    // HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
    // 原本独立的 `parametersSection`（按任务调 Temperature/Top P/Top K/MaxToken/
    // Timeout/Stream）已删除。参数现在与"模型"绑定，编辑入口在"已发现模型"列表
    // 每行最右侧的齿轮按钮 → popover（`AIModelParametersPopover`）。
    //
    // 删除的辅助函数：parametersSection / parameterSlider / parameterIntField /
    // parameterDoubleBinding / parameterIntBinding / parameterBoolBinding /
    // parameterMaxTokensKBinding / parameterTimeoutSecondsBinding——这些都是
    // "task → AIModelParameters" 路径上的辅助，迁移后 popover 内部自带等价控件。

    /// HOM-68 follow-up v5 (dong4j 反馈 2026-06-05 23:00)：
    /// v4 用 `Text + onTapGesture` 不生效——SwiftUI 在 `Form(.grouped)` 里给
    /// `DisclosureGroup` label 套了一层非交互容器，会吞掉 `onTapGesture`，
    /// 只有 chevron 内置的 hit area 才能触发。
    ///
    /// 改用 `Button(action:) + .buttonStyle(.plain)`：Button 在 Form 里是
    /// SwiftUI 一等公民，永远拿到点击事件；plain style 抹掉默认按钮装饰，
    /// 视觉上仍是普通标题文字。
    ///
    /// 用 withAnimation 让展开/折叠跟 chevron 旋转走同一条动画曲线，避免"点
    /// 标题瞬切、点 chevron 平滑"的不一致体感。
    private func disclosureLabel(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    // 与 SettingsSectionHeader prominent 的分组图标同口径（13pt / 20×20），
                    // 让 DisclosureGroup 标题和 Section 分组标题在 Form 里同一视觉层级。
                    .font(SettingsIconMetrics.smallGlyph)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                Text(titleKey)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // HOM-68 follow-up v10 (dong4j 反馈 2026-06-05 23:55)：项目强制规则
        // (docs/3-设计/详细设计/07-UI交互设计.md §1.2 + CLAUDE.md §UI Focus Ring)——
        // 所有 .buttonStyle(.plain) Button 必须紧跟 .focusEffectDisabled()，否则
        // macOS 15+ 会在聚焦时套一个蓝色 focus ring，与项目暗色面板视觉冲突。
        .focusEffectDisabled()
    }

    // MARK: - Auto Tidy (HOM-126)

    /// 沿用模型与翻译页的说明卡片结构，卡片表面由原生 grouped Form 提供。
    private var automationIntroductionSection: some View {
        Section {
            HStack(spacing: 16) {
                BusinessIcon(.automation, pointSize: 24)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.automation.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text("settings.automation.title"))
                    Text("settings.automation.introduction.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text("settings.automation.introduction.description"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    /// 常用操作常驻；标签细节与运行规则并列折叠。总开关的禁用范围保持原样，
    /// 包括运行状态和手动执行，避免仅调整布局时改变调度器的使用条件。
    private var autoTidySection: some View {
        Section {
            autoTidyContent
        } header: {
            SettingsSectionHeader(
                "settings.automation.local.section",
                businessIcon: .tags
            )
        }
    }

    /// 仓库分组的独立全局配置。
    ///
    /// 标签是 Starcat 本地数据，而仓库分组会写入 GitHub Lists。两者的授权边界和
    /// 置信度不能放在同一个配置组里，否则调整标签策略时可能意外改变远端写入行为。
    /// 常用阈值常驻，自己的运行规则默认收起，不能与本地整理共享折叠或配置状态。
    private var githubListGroupingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                // 与本地整理总开关同款：标题与备注分行，避免 Toggle thumb 被挤出裁切。
                // 备注只说后台整理未分组仓库；启动 / 同步触发已拆到下方独立开关，不能再写死。
                Toggle("settings.automation.grouping.enabled", isOn: githubListGroupingBinding(\.enabled))
                    .toggleStyle(.switch)
                    .padding(.vertical, 8)

                Text("settings.githubListGrouping.enabled.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)

                Group {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("settings.githubListGrouping.threshold.label") {
                            Text(verbatim: githubListGroupingThresholdPercentString)
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.tint)
                        }
                        Slider(
                            value: githubListGroupingBinding(\.confidenceThreshold),
                            in: 0.5...1.0,
                            step: 0.05
                        )
                        .controlSize(.mini)
                        Text(String(
                            format: String.l10n("settings.githubListGrouping.threshold.hintFormat"),
                            githubListGroupingThresholdPercentString
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)

                    Divider()
                    automationDisclosure(
                        "settings.automation.rules.title",
                        summary: listGroupingRulesSummary,
                        isExpanded: $isListGroupingRulesExpanded
                    ) {
                        githubListGroupingTriggerGroup
                        githubListGroupingRangeGroup
                    }
                }
                .disabled(!settings.githubStarListAutoGroupingSettings.enabled)
                .opacity(settings.githubStarListAutoGroupingSettings.enabled ? 1.0 : 0.5)
            }
            .padding(.top, 4)
        } header: {
            SettingsSectionHeader(
                "settings.automation.grouping.section",
                businessIcon: .groups
            )
        } footer: {
            Text("settings.githubListGrouping.footer")
        }
    }

    /// 仓库分组拥有自己的触发策略，不能借用标签整理开关；否则用户关闭“同步后加标签”
    /// 时会意外停止 GitHub Lists 整理，或反过来被不相关的触发器启动。
    @ViewBuilder
    private var githubListGroupingTriggerGroup: some View {
        Divider()

        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.trigger.onLaunch",
                description: "settings.githubListGrouping.trigger.onLaunch.description",
                isOn: githubListGroupingBinding(\.triggerOnLaunch)
            )
        }
        Divider()
        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.trigger.onSync",
                description: "settings.githubListGrouping.trigger.onSync.description",
                isOn: githubListGroupingBinding(\.triggerOnSync)
            )
        }
        Divider()
        autoTidyRow {
            Toggle(
                "settings.autoTidy.trigger.scheduled",
                isOn: githubListGroupingBinding(\.triggerScheduled)
            )
        }
        Divider()
        autoTidyRow {
            LabeledContent {
                TextField(
                    "",
                    value: githubListGroupingScheduledIntervalHoursBinding,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .help("1 - 24")
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.trigger.scheduledInterval",
                    description: "settings.autoTidy.trigger.scheduledInterval.description"
                )
            }
            .disabled(!settings.githubStarListAutoGroupingSettings.triggerScheduled)
            .opacity(settings.githubStarListAutoGroupingSettings.triggerScheduled ? 1.0 : 0.5)
        }
    }

    /// 后台分组只从“未分组”仓库里按此范围取候选；v34 持久化的 OAuth 限制仓库会在
    /// 截取批量前排除，不能占用用户配置的单轮数量。
    @ViewBuilder
    private var githubListGroupingRangeGroup: some View {
        Divider()

        autoTidyRow {
            LabeledContent {
                TextField(
                    "",
                    value: githubListGroupingMaxPerRunBinding,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .help("5 - 500")
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.range.maxPerRun",
                    description: "settings.githubListGrouping.range.maxPerRun.description"
                )
            }
        }
        Divider()
        autoTidyRow {
            Picker(selection: githubListGroupingBinding(\.sortOrder)) {
                ForEach(AutoTidySortOrder.allCases) { order in
                    Text(order.displayNameKey).tag(order)
                }
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.range.sortOrder",
                    description: "settings.githubListGrouping.range.sortOrder.description"
                )
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var autoTidyContent: some View {
        // 配置面板内不会自动出现 Form 行分隔线，
        // 改用 VStack(spacing: 0) + Divider + 统一行 padding，对齐通用设置页节奏。
        VStack(spacing: 0) {
            // 总开关：标题行与说明分两行，避免 LabeledContent 把 Toggle thumb 挤出裁切。
            Toggle("settings.automation.local.enabled", isOn: autoTidyBinding(\.enabled))
                .toggleStyle(.switch)
                .padding(.vertical, 8)

            Text("settings.autoTidy.enabled.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            Group {
                Divider()
                autoTidyRow {
                    autoTidyToggle(
                        title: "settings.autoTidy.actions.generateTags",
                        description: "settings.autoTidy.actions.generateTags.description",
                        isOn: autoTidyBinding(\.generateTags)
                    )
                }
                Divider()
                autoTidyRow {
                    autoTidyToggle(
                        title: "settings.autoTidy.actions.generateSummary",
                        description: "settings.autoTidy.actions.generateSummary.description",
                        isOn: autoTidyBinding(\.generateSummary)
                    )
                }
                Divider()
                automationDisclosure(
                    "settings.automation.tagPolicy.title",
                    summary: tagPolicySummary,
                    isExpanded: $isTagPolicyExpanded
                ) {
                    tagPolicyGroup
                }
                .disabled(!settings.autoTidySettings.generateTags)
                .opacity(settings.autoTidySettings.generateTags ? 1.0 : 0.5)

                Divider()
                automationDisclosure(
                    "settings.automation.rules.title",
                    summary: autoTidyRulesSummary,
                    isExpanded: $isAutoTidyRulesExpanded
                ) {
                    triggerGroup
                    rangeGroup
                }
                statusGroup
            }
            .disabled(!settings.autoTidySettings.enabled)
            .opacity(settings.autoTidySettings.enabled ? 1.0 : 0.5)
        }
        .padding(.top, 4)
    }

    /// 整行切换展开，右侧箭头只表达状态；摘要可截断但完整内容保留在 tooltip 和辅助功能中。
    private func automationDisclosure<Content: View>(
        _ title: LocalizedStringKey,
        summary: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(verbatim: summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text(summary))
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: [
                String.l10n(isExpanded.wrappedValue
                    ? "settings.general.disclosure.expanded"
                    : "settings.general.disclosure.collapsed"),
                summary
            ].joined(separator: " · ")))

            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    /// 跳转已有任务模型页，不在自动化页面复制模型配置或增加第二份状态。
    private var automationModelsSection: some View {
        Section {
            HStack {
                Spacer()
                Button("settings.automation.manageModels") {
                    NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.models")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    /// 配置行统一竖向 padding，避免 Toggle / LabeledContent / Picker 行高不一致。
    private func autoTidyRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 8)
    }

    /// 标题 + caption 备注：设置页行 Label 标准结构（见 UI-设置页规范）。
    private func autoTidyLabel(title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 带备注的 Toggle，避免每个开关重复拼 VStack。
    private func autoTidyToggle(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            autoTidyLabel(title: title, description: description)
        }
    }

    /// 触发时机：启动后一次 / 同步后增量 / 定时（可配间隔）。
    @ViewBuilder
    private var triggerGroup: some View {
        Divider()

        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.trigger.onLaunch",
                description: "settings.autoTidy.trigger.onLaunch.description",
                isOn: autoTidyBinding(\.triggerOnLaunch)
            )
        }
        Divider()
        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.trigger.onSync",
                description: "settings.autoTidy.trigger.onSync.description",
                isOn: autoTidyBinding(\.triggerOnSync)
            )
        }
        Divider()
        autoTidyRow {
            Toggle("settings.autoTidy.trigger.scheduled", isOn: autoTidyBinding(\.triggerScheduled))
        }
        Divider()

        // 间隔仅在「定时执行」打开时有意义；关掉时淡化 + disable，保留上次填写值。
        autoTidyRow {
            LabeledContent {
                TextField(
                    "",
                    value: scheduledIntervalHoursBinding,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .help("1 - 24")
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.trigger.scheduledInterval",
                    description: "settings.autoTidy.trigger.scheduledInterval.description"
                )
            }
            .disabled(!settings.autoTidySettings.triggerScheduled)
            .opacity(settings.autoTidySettings.triggerScheduled ? 1.0 : 0.5)
        }
    }

    /// 处理范围：批处理数量 + 处理优先级。
    @ViewBuilder
    private var rangeGroup: some View {
        Divider()

        // HOM-126 follow-up (dong4j 反馈 2026-06-07)：Stepper → TextField + 数字校验。
        // SwiftUI `TextField(value:format: .number)` 内置只接受数字输入（非数字字符被吃掉），
        // setter 在 `maxPerRunBinding` 内已 clamp 到 5...500，超范围 / 失焦后 binding 把值约束回区间。
        // 用 `IntegerFormatStyle.number.grouping(.never)` 关掉千位分隔符，避免显示 "1,000"。
        // 输入框右对齐 + 80pt 固定宽度，与其他「数字配置项」视觉对齐。
        autoTidyRow {
            LabeledContent {
                TextField(
                    "",
                    value: maxPerRunBinding,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .help("5 - 500")
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.range.maxPerRun",
                    description: "settings.autoTidy.range.maxPerRun.description"
                )
            }
        }
        Divider()
        autoTidyRow {
            Picker(selection: autoTidyBinding(\.sortOrder)) {
                ForEach(AutoTidySortOrder.allCases) { order in
                    Text(order.displayNameKey).tag(order)
                }
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.range.sortOrder",
                    description: "settings.autoTidy.range.sortOrder.description"
                )
            }
            .pickerStyle(.menu)
        }
    }

    /// 仅收起标签参数；数量依然写入手动与自动整理共用的范围，阈值禁用条件保持不变。
    @ViewBuilder
    private var tagPolicyGroup: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                autoTidyLabel(
                    title: "settings.autoTidy.tagSuggestionCount",
                    description: "settings.autoTidy.tagSuggestionCount.description"
                )
                Spacer(minLength: 12)
                AITagSuggestionCountRangeControl(
                    minimum: settings.aiTagSuggestionMinCount,
                    maximum: settings.aiTagSuggestionMaxCount,
                    style: .regular
                ) { minimum, maximum in
                    settings.applyAITagSuggestionCounts(minimum: minimum, maximum: maximum)
                }
            }
        }
        .padding(.vertical, 8)
        Divider()

        // HOM-126 follow-up (dong4j 反馈 2026-06-07，截图：阈值 label 没有独立开关)：
        // 标签阈值区两层 disable：
        //   - 外层（整组）：标签关闭时整组 disable；
        //   - 内层（仅滑块）：`useConfidenceThreshold = false` → 阈值 Toggle 行还能点开，但滑块 disable，
        //     `makeBatchOptions` 把下游阈值降级为 0（不过滤，所有标签都自动应用）。
        Group {
            autoTidyRow {
                Toggle("settings.autoTidy.threshold.enabled", isOn: autoTidyBinding(\.useConfidenceThreshold))
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("settings.autoTidy.threshold.label")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: thresholdPercentString)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
                Slider(value: autoTidyBinding(\.confidenceThreshold), in: 0.5...1.0, step: 0.05)
                    .controlSize(.mini)
                Text(String(format: String.l10n("settings.autoTidy.threshold.hintFormat"), thresholdPercentString))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .disabled(!settings.autoTidySettings.useConfidenceThreshold)
            .opacity(settings.autoTidySettings.useConfidenceThreshold ? 1.0 : 0.5)
        }
    }

    /// 保留真实调度进度、上次结果与右对齐操作；仍需先开总开关，且不能在运行中重复触发。
    @ViewBuilder
    private var statusGroup: some View {
        Divider()
        HStack {
            Spacer()
            Text("settings.automation.status.title")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)

        // 备注与执行按钮同排；长译文可截断并通过提示查看，优先保证按钮完整可见。
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text(lastRunSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(Text(lastRunSummaryText))

            Spacer(minLength: 12)

            if autoTidyScheduler.isAutoTidyRunning {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: autoTidyScheduler.autoTidyProgressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                autoTidyScheduler.triggerManually()
            } label: {
                Label("settings.automation.triggerNow", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .fixedSize()
            // 已经在跑就 disable，避免重复触发；调度器内部也有 `batchService.isRunning` 检查兜底
            .disabled(autoTidyScheduler.isAutoTidyRunning || !settings.autoTidySettings.hasAnyAction)
        }
        .padding(.vertical, 8)
    }

    /// 「上次自动跑：X 分钟前 · 应用 12 / 忽略 3 / 失败 1」。
    /// 没有记录时给"尚未运行"文案。
    private var lastRunSummaryText: String {
        guard let last = settings.autoTidySettings.lastRunAt,
              let stats = settings.autoTidySettings.lastRunStats else {
            return String.l10n("settings.autoTidy.status.neverRun")
        }
        let timeAgo = RelativeTimeText.pastEvent(last, locale: locale)
        return String(
            format: String.l10n("settings.autoTidy.status.lastRunFormat"),
            timeAgo, stats.applied, stats.ignored, stats.failed
        )
    }

    private var thresholdPercentString: String {
        settings.autoTidySettings.confidenceThreshold.formatted(
            .percent.precision(.fractionLength(0)).locale(locale)
        )
    }

    /// 仓库分组拥有独立阈值，不能与标签自动应用共用同一显示值。
    private var githubListGroupingThresholdPercentString: String {
        settings.githubStarListAutoGroupingSettings.confidenceThreshold.formatted(
            .percent.precision(.fractionLength(0)).locale(locale)
        )
    }

    /// 摘要只读取现有配置；关闭过滤时仍保留阈值，不能为简化显示而改写真实设置。
    private var tagPolicySummary: String {
        let count = String(
            format: String.l10n("settings.automation.tagPolicy.rangeFormat"),
            settings.aiTagSuggestionMinCount.formatted(.number.locale(locale)),
            settings.aiTagSuggestionMaxCount.formatted(.number.locale(locale))
        )
        let policy = settings.autoTidySettings.useConfidenceThreshold
            ? String(format: String.l10n("settings.automation.tagPolicy.thresholdFormat"), thresholdPercentString)
            : String.l10n("settings.automation.tagPolicy.unfiltered")
        let parts = settings.autoTidySettings.generateTags
            ? [count, policy]
            : [String.l10n("settings.automation.tagPolicy.disabled"), count, policy]
        return parts.joined(separator: " · ")
    }

    private var autoTidyRulesSummary: String {
        let tidy = settings.autoTidySettings
        return automationRulesSummary(
            onLaunch: tidy.triggerOnLaunch, onSync: tidy.triggerOnSync,
            scheduled: tidy.triggerScheduled, hours: tidy.scheduledIntervalHours, count: tidy.maxPerRun
        )
    }

    private var listGroupingRulesSummary: String {
        let grouping = settings.githubStarListAutoGroupingSettings
        return automationRulesSummary(
            onLaunch: grouping.triggerOnLaunch, onSync: grouping.triggerOnSync,
            scheduled: grouping.triggerScheduled, hours: grouping.scheduledIntervalHours, count: grouping.maxPerRun
        )
    }

    /// 两组规则复用展示格式，数据仍分别来自各自配置；数字显式跟随应用 locale。
    private func automationRulesSummary(
        onLaunch: Bool, onSync: Bool, scheduled: Bool, hours: Int, count: Int
    ) -> String {
        var parts: [String] = []
        if onLaunch { parts.append(String.l10n("settings.automation.rules.launch")) }
        if onSync { parts.append(String.l10n("settings.automation.rules.sync")) }
        if scheduled {
            parts.append(String(
                format: String.l10n("settings.automation.rules.intervalFormat"),
                hours.formatted(.number.locale(locale))
            ))
        }
        if parts.isEmpty { parts.append(String.l10n("settings.automation.rules.none")) }
        parts.append(String(
            format: String.l10n("settings.automation.rules.batchFormat"),
            count.formatted(.number.locale(locale))
        ))
        return parts.joined(separator: " · ")
    }

    // MARK: - Auto Tidy Bindings

    /// 通用 binding helper：把 `AutoTidySettings` 的某个 keyPath 绑成可写 Binding。
    /// 写入时整段 settings 重新赋值，触发 `AppSettings.autoTidySettings.didSet` 持久化。
    private func autoTidyBinding<T>(_ keyPath: WritableKeyPath<AutoTidySettings, T>) -> Binding<T> {
        return Binding(
            get: { self.settings.autoTidySettings[keyPath: keyPath] },
            set: { newValue in
                var s = self.settings.autoTidySettings
                s[keyPath: keyPath] = newValue
                self.settings.autoTidySettings = s
            }
        )
    }

    /// GitHub Lists 自动分组使用独立 settings/key，不能借用标签分类的 Binding helper。
    private func githubListGroupingBinding<T>(
        _ keyPath: WritableKeyPath<GitHubStarListAutoGroupingSettings, T>
    ) -> Binding<T> {
        Binding(
            get: { self.settings.githubStarListAutoGroupingSettings[keyPath: keyPath] },
            set: { newValue in
                var grouping = self.settings.githubStarListAutoGroupingSettings
                grouping[keyPath: keyPath] = newValue
                self.settings.githubStarListAutoGroupingSettings = grouping
            }
        )
    }

    /// 数字输入仍 clamp 到原来的 5...500，不因配置行移入折叠区而放宽范围。
    private var maxPerRunBinding: Binding<Int> {
        Binding(
            get: { self.settings.autoTidySettings.maxPerRun },
            set: { newValue in
                let clamped = max(5, min(500, newValue))
                var s = self.settings.autoTidySettings
                s.maxPerRun = clamped
                self.settings.autoTidySettings = s
            }
        )
    }

    /// 定期间隔（小时）binding：clamp 到 `AutoTidySettings.scheduledIntervalHoursRange`。
    private var scheduledIntervalHoursBinding: Binding<Int> {
        Binding(
            get: { self.settings.autoTidySettings.scheduledIntervalHours },
            set: { newValue in
                var s = self.settings.autoTidySettings
                s.scheduledIntervalHours = AutoTidySettings.clampScheduledIntervalHours(newValue)
                self.settings.autoTidySettings = s
            }
        )
    }

    private var githubListGroupingMaxPerRunBinding: Binding<Int> {
        Binding(
            get: { self.settings.githubStarListAutoGroupingSettings.maxPerRun },
            set: { newValue in
                var grouping = self.settings.githubStarListAutoGroupingSettings
                grouping.maxPerRun = GitHubStarListAutoGroupingSettings.clampMaxPerRun(newValue)
                self.settings.githubStarListAutoGroupingSettings = grouping
            }
        )
    }

    private var githubListGroupingScheduledIntervalHoursBinding: Binding<Int> {
        Binding(
            get: { self.settings.githubStarListAutoGroupingSettings.scheduledIntervalHours },
            set: { newValue in
                var grouping = self.settings.githubStarListAutoGroupingSettings
                grouping.scheduledIntervalHours =
                    GitHubStarListAutoGroupingSettings.clampScheduledIntervalHours(newValue)
                self.settings.githubStarListAutoGroupingSettings = grouping
            }
        )
    }

    // MARK: - AI 索引（向量搜索改进 2026-06-12）

    /// "向量化索引" Section（原 "AI 索引"，HOM-197 2026-06-13 改名）：
    /// README 截断长度滑杆 + 搜索结果过滤阈值滑杆 + 三档阈值预设 + 折叠区精细数字 + 预拉 / 全量重建按钮。
    ///
    /// UI 形态：
    /// ```
    /// 向量化索引 ▼
    ///   ┌ README 截断长度 ──── 滑杆 [12000] ──── 12000 字符
    ///   ├ 搜索结果过滤阈值 ─── 滑杆 [75%] ────── 75%      ← HOM-197 新增
    ///   ├ 阈值预设      ── 严格 / 标准 / 宽松 / 自定义
    ///   ├ 高级（折叠）  ── 主体阈值 Slider + 笔记阈值 Slider   ← HOM-197 Stepper→Slider
    ///   ├ ─────────────────────
    ///   ├ 启动自动预拉 [开关]
    ///   ├ 进度 234 / 1801（失败 0）          [开始预拉 / 暂停]   ← 按钮右对齐
    ///   └ 强制…会消耗配额。                 [⚠ 全量重建]       ← 文案左、按钮右
    /// ```
    ///
    /// 切换预设时通过 `applyAIIndexPreset(_:)` 把 body / notes 具体数字同步过去，避免
    /// 折叠区显示 10/20 但实际生效 5/10 的"漂移"。
    private var aiIndexSection: some View {
        Section {
            // 顶级配置区始终展开；仅内部“高级”参数继续按需折叠，保留主次层级。
            VStack(alignment: .leading, spacing: 0) {
                truncateLengthRow
                    .padding(.vertical, 8)
                Divider()
                scoreThresholdRow
                    .padding(.vertical, 8)
                Divider()
                presetRow
                    .padding(.vertical, 8)
                Divider()
                advancedDisclosure
                    .padding(.vertical, 8)
                Divider()
                Toggle("settings.aiIndex.autoPrefetch", isOn: autoPrefetchBinding)
                    .padding(.vertical, 8)
                Divider()
                builderControlsRow
                    .padding(.vertical, 8)
                Divider()
                rebuildAllRow
                    .padding(.vertical, 8)
            }
            .padding(.top, 4)
        } header: {
            SettingsSectionHeader(
                "settings.aiIndex.section",
                businessIcon: .aiIndex
            )
        }
    }

    /// 截断长度滑杆 + 数字读数。
    /// 决策 C2：范围 2000-32000，步进 1000。
    private var truncateLengthRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("settings.aiIndex.truncateLength")
                    .font(.callout)
                Spacer()
                Text("\(settings.aiReadmeTruncateLength)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: truncateLengthBinding,
                in: 2000...32000,
                step: 1000
            )
            Text("settings.aiIndex.truncateLength.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// HOM-197（2026-06-13 dong4j）：搜索结果过滤阈值滑杆。
    ///
    /// 形态完全复用 `truncateLengthRow` 骨架（标题 + 右上百分比 + Slider + 下方 hint），
    /// 让用户在同一组里横向看到的滑杆视觉语言一致。
    ///
    /// 配置：10% - 100%，步进 1%，默认 75%。生效路径见 `AppSettings
    /// .aiSemanticSearchScoreThreshold` 文档与 `HomeViewModel.applyView()` 的语义分支。
    private var scoreThresholdRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("settings.aiIndex.scoreThreshold")
                    .font(.callout)
                Spacer()
                Text("\(Int((settings.aiSemanticSearchScoreThreshold * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: scoreThresholdBinding,
                in: 0.10...1.00,
                step: 0.01
            )
            Text("settings.aiIndex.scoreThreshold.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 三档预设 + custom：segmented picker；switch 时同步 body/notes 字段。
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("settings.aiIndex.preset")
                    .font(.callout)
                Spacer()
            }
            EqualWidthSegmentedControl(
                items: Array(AIIndexPreset.allCases),
                selection: presetBinding,
                title: { LocalizedStringKey($0.displayNameKey) }
            )
        }
    }

    /// 高级区（折叠）：body / notes 阈值滑杆（HOM-197 2026-06-13 由 Stepper 改为 Slider）。
    /// 预设 != custom 时禁用编辑，提示用户先切到自定义。
    @ViewBuilder
    private var advancedDisclosure: some View {
        let isCustom = settings.aiIndexPreset == .custom
        DisclosureGroup(isExpanded: $isAIIndexAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ratioRow(
                    titleKey: "settings.aiIndex.bodyThreshold",
                    value: bodyRatioBinding,
                    enabled: isCustom
                )
                .padding(.vertical, 8)
                Divider()
                ratioRow(
                    titleKey: "settings.aiIndex.notesThreshold",
                    value: notesRatioBinding,
                    enabled: isCustom
                )
                .padding(.vertical, 8)
                if !isCustom {
                    Divider()
                    Text("settings.aiIndex.advanced.lockedHint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .padding(.top, 4)
        } label: {
            disclosureLabel("settings.aiIndex.advanced", systemImage: "slider.horizontal.3", isExpanded: $isAIIndexAdvancedExpanded)
        }
    }

    /// 阈值行：与 `truncateLengthRow` / `scoreThresholdRow` 同款骨架——
    /// 标题 + 右上百分比读数 + Slider（HOM-197 dong4j 反馈，2026-06-13）。
    ///
    /// 范围 1% - 90%、步进 1%：
    /// - **下限 1%**：0% 意味着"任何字符差异都重建"会把 embedding 配额烧爆，
    ///   1% 起作为安全护栏；
    /// - **上限 90%**：现有最宽松预设 relaxed 是 20/30%，留出充足 headroom 给极端
    ///   "几乎不重建"场景；100% 等价于"永不自动重建" 没有实用意义；
    /// - 默认沿用 `DiffThresholds.default`（body 10% / notes 20%，即 standard 预设）。
    ///
    /// 预设非 `.custom` 时滑杆 `.disabled(!enabled)`；用户拖动后 binding 会自动把
    /// 预设切到 `.custom`（在 `bodyRatioBinding` / `notesRatioBinding` 的 set 闭包内
    /// 完成，与原 Stepper 行为一致）。
    private func ratioRow(titleKey: String, value: Binding<Double>, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(titleKey))
                    .font(.callout)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0.01...0.90, step: 0.01)
                .disabled(!enabled)
        }
    }

    /// 开始 / 暂停 / 进度行。
    ///
    /// **布局（设置页按钮右对齐规范）**：进度 / 上次预拉记录在左，操作按钮在右。
    /// 进程内 `.idle` 不再留空：打开设置页时读落盘的上次预拉时间和计数。
    @ViewBuilder
    private var builderControlsRow: some View {
        let builder = dependencies.semanticIndexBuilder
        HStack(spacing: 10) {
            builderProgressView
            Spacer()
            switch builder.status {
            case .idle, .completed, .alreadyUpToDate, .failed:
                Button(String.l10n("settings.aiIndex.prefetch.start")) {
                    builder.start()
                }
            case .running:
                Button(String.l10n("settings.aiIndex.prefetch.pause")) {
                    builder.pause()
                }
            case .paused:
                Button(String.l10n("settings.aiIndex.prefetch.resume")) {
                    builder.resume()
                }
            }
        }
    }

    /// 左侧进度 / 上次预拉记录。进行中显示活进度；其余状态显示落盘快照和相对时间。
    @ViewBuilder
    private var builderProgressView: some View {
        let builder = dependencies.semanticIndexBuilder
        switch builder.status {
        case .running:
            prefetchLiveProgress(
                icon: "arrow.triangle.2.circlepath",
                processed: builder.processed,
                total: builder.total,
                failures: builder.failures,
                tint: .accentColor
            )
        case .paused:
            prefetchLiveProgress(
                icon: "pause.circle.fill",
                processed: builder.processed,
                total: builder.total,
                failures: builder.failures,
                tint: RAGBackendTestStatus.warningTint
            )
        default:
            lastPrefetchRecordView
        }
    }

    /// 进行中用 accent 同步箭头，暂停用橙色暂停图标；失败数 > 0 时改警告色。
    private func prefetchLiveProgress(
        icon: String,
        processed: Int,
        total: Int,
        failures: Int,
        tint: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(failures > 0 ? RAGBackendTestStatus.warningTint : tint)
                .font(.callout)
            Text(
                String(
                    format: String.l10n("settings.aiIndex.prefetch.progressFmt"),
                    processed, total, failures
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    /// 打开设置页就能看到上次预拉时间和记录。没有快照时显示尚未预拉。
    @ViewBuilder
    private var lastPrefetchRecordView: some View {
        if let last = settings.semanticIndexLastPrefetch {
            let timeAgo = RelativeTimeText.pastEvent(last.finishedAt, locale: locale)
            HStack(spacing: 6) {
                Image(systemName: lastPrefetchIcon(last))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(lastPrefetchBadgeColor(last))
                    .font(.callout)
                Text(
                    String(
                        format: String.l10n("settings.aiIndex.prefetch.lastRunFormat"),
                        timeAgo,
                        lastPrefetchRecordText(last)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text("settings.aiIndex.prefetch.neverRun")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func lastPrefetchRecordText(_ last: SemanticIndexPrefetchLastRun) -> String {
        switch last.outcome {
        case .alreadyUpToDate:
            return String(format: String.l10n("settings.aiIndex.prefetch.alreadyUpToDateFmt"), last.total)
        case .completed:
            return String(
                format: String.l10n("settings.aiIndex.prefetch.progressFmt"),
                last.processed, last.total, last.failures
            )
        case .failed:
            return String(
                format: String.l10n("settings.aiIndex.prefetch.failedFmt"),
                last.failureMessage ?? ""
            )
        }
    }

    private func lastPrefetchIcon(_ last: SemanticIndexPrefetchLastRun) -> String {
        switch last.outcome {
        case .alreadyUpToDate:
            return "checkmark.circle.fill"
        case .completed:
            return last.failures == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private func lastPrefetchBadgeColor(_ last: SemanticIndexPrefetchLastRun) -> Color {
        switch last.outcome {
        case .alreadyUpToDate:
            return RAGBackendTestStatus.successTint
        case .completed:
            return last.failures == 0 ? RAGBackendTestStatus.successTint : RAGBackendTestStatus.warningTint
        case .failed:
            return RAGBackendTestStatus.dangerTint
        }
    }

    /// "全量重建"按钮。点击只弹确认 dialog，实际执行在 body 的 `.confirmationDialog`。
    ///
    /// **布局（设置页按钮右对齐规范）**：消耗配额提示在左，destructive 按钮在右。
    private var rebuildAllRow: some View {
        HStack(spacing: 10) {
            Text("settings.aiIndex.rebuildAll.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(role: .destructive) {
                pendingRebuildAllConfirm = true
            } label: {
                Label("settings.aiIndex.rebuildAll.button", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: - AI 索引 bindings

    private var truncateLengthBinding: Binding<Double> {
        Binding(
            get: { Double(self.settings.aiReadmeTruncateLength) },
            set: { newValue in
                self.settings.aiReadmeTruncateLength = Int(newValue.rounded())
            }
        )
    }

    /// HOM-197：阈值滑杆 binding。
    /// `set` 端 clamp 到 [0.10, 1.00]——SwiftUI Slider 在 `step` 截断 + 浮点抖动下
    /// 偶尔会写出超出 `in:` 范围 1e-9 的值，clamp 是防御性兜底。
    private var scoreThresholdBinding: Binding<Double> {
        Binding(
            get: { self.settings.aiSemanticSearchScoreThreshold },
            set: { newValue in
                self.settings.aiSemanticSearchScoreThreshold = max(0.10, min(1.00, newValue))
            }
        )
    }

    private var presetBinding: Binding<AIIndexPreset> {
        Binding(
            get: { self.settings.aiIndexPreset },
            set: { self.settings.applyAIIndexPreset($0) }
        )
    }

    private var bodyRatioBinding: Binding<Double> {
        Binding(
            get: { self.settings.aiIndexBodyDiffRatio },
            set: { newValue in
                let clamped = max(0, min(1, newValue))
                self.settings.aiIndexBodyDiffRatio = clamped
                // 用户在高级区改具体数字 → 自动切到 custom（避免显示"标准"但数字漂移）
                if self.settings.aiIndexPreset != .custom {
                    self.settings.aiIndexPreset = .custom
                }
            }
        )
    }

    private var notesRatioBinding: Binding<Double> {
        Binding(
            get: { self.settings.aiIndexNotesDiffRatio },
            set: { newValue in
                let clamped = max(0, min(1, newValue))
                self.settings.aiIndexNotesDiffRatio = clamped
                if self.settings.aiIndexPreset != .custom {
                    self.settings.aiIndexPreset = .custom
                }
            }
        )
    }

    private var autoPrefetchBinding: Binding<Bool> {
        Binding(
            get: { self.settings.aiIndexAutoPrefetchEnabled },
            set: { self.settings.aiIndexAutoPrefetchEnabled = $0 }
        )
    }

    // MARK: - AI 代码上下文（2026-06-13 §0.4 Y3）
    //
    // 「AI 代码上下文」分组，对应 §0 客户端接入任务清单 §0.4 触点 C。
    //
    // 设计要点（沿用 autoTidySection / aiIndexSection 同款顶级配置风格）：
    //   - 标题放在面板外，配置内容始终展示；
    //   - 总开关 Toggle 控制下面控件的 disabled 状态（用户关掉总开关后调下面没意义）；
    //   - Token 与 ZIP 上限 Slider 走 Int↔Double 适配；行数使用数字 TextField，遵守禁止 Stepper 规范；
    //   - **不提供「私有仓库」开关**：当前 OAuth scope 是 `read:user` + `public_repo`，
    //     API 永远不会返回 isPrivate=true 的 repo；增加一个永远走不到的开关只会污染设置页；
    //
    // 关键约束：
    //   - 本 section 完全是 UI 层；改字段值只写 AppSettings UserDefaults，不触发任何 AI / 网络 / 磁盘 I/O。
    //   - 用户改 Slider/TextField 后立即落盘（didSet），下次生成 AI 摘要时读取一次配置快照。

    private var aiRepoContextSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                repoContextEnableRow
                    .padding(.vertical, 8)
                Divider()
                repoContextTokenBudgetRow
                    .padding(.vertical, 8)
                Divider()
                repoContextMaximumArchiveSizeRow
                    .padding(.vertical, 8)
                Divider()
                repoContextTier1MaxLinesRow
                    .padding(.vertical, 8)
                Divider()
                repoContextManageStorageRow
                    .padding(.vertical, 8)
            }
            .padding(.top, 4)
        } header: {
            SettingsSectionHeader(
                "ai.context.settings.title",
                businessIcon: .codeContext
            )
        }
    }

    /// 总开关 + 一段说明 caption。
    /// caption 解释「会做什么 + 首次生成耗时预期」，让用户开启前有合理预期。
    private var repoContextEnableRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("ai.context.settings.enabled", isOn: repoContextEnabledBinding)
            Text("ai.context.settings.description")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Token 预算 Slider 行。范围 4000-32000、步进 2000——8 档刻度，
    /// 既不会让用户感到"想精调但跳得太大"，也不会让"步进 100"显得选择困难。
    private var repoContextTokenBudgetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ai.context.settings.tokenBudget")
                    .font(.callout)
                Spacer()
                Text("\(settings.aiRepoContextTokenBudget) tokens")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: tokenBudgetBinding,
                in: 4000...32000,
                step: 2000
            )
            .disabled(!settings.aiRepoContextEnabled)
        }
    }

    /// 源码 ZIP 大小上限。沿用 Token 预算的标题 + 数值 + Slider 结构，避免同一设置组
    /// 出现两套数值配置交互；1...500MB 的值会同时传给下载层与 Packer 解压预检。
    private var repoContextMaximumArchiveSizeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ai.context.settings.maximumArchiveSize")
                    .font(.callout)
                Spacer()
                Text("\(settings.aiRepoContextMaximumArchiveMB) MB")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: maximumArchiveSizeBinding,
                in: Double(AppSettings.aiRepoContextMaximumArchiveMBRange.lowerBound)...Double(
                    AppSettings.aiRepoContextMaximumArchiveMBRange.upperBound
                ),
                step: 1
            )
            Text("ai.context.settings.maximumArchiveSize.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Tier 1 关键文件保留行数输入行。范围 40-200。
    /// 项目 UI 规范禁止 Stepper，所以这里使用数字 TextField，并在 binding setter 里钳制范围。
    ///
    /// HOM-203：右侧读数原本写成 `Text("ai.context...Format \(value)")`，被 SwiftUI
    /// 编译成 LocalizedStringKey `"ai.context...Format %@"`，xcstrings 中该带 `%@`
    /// 的 entry 是空壳，运行时找不到翻译就回退成"显示 key 字面量"，于是用户看到
    /// `ai.context.settings.tier1MaxLinesValueFormat 100` 这种纯 key。改成显式
    /// `String.l10n + String(format:)`，与本视图其它行（如 line 1480 的统计 cell）
    /// 风格保持一致；翻译模板里把 `%lld` 当行数占位符使用。
    private var repoContextTier1MaxLinesRow: some View {
        HStack {
            Text("ai.context.settings.tier1MaxLines")
                .font(.callout)
            Spacer()
            Text(String(
                format: String.l10n("ai.context.settings.tier1MaxLinesValueFormat"),
                settings.aiRepoContextTier1MaxLines
            ))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            TextField(
                "",
                value: repoContextTier1MaxLinesBinding,
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospacedDigit())
            .frame(width: 72)
            .disabled(!settings.aiRepoContextEnabled)
        }
    }

    // MARK: - AI 代码上下文产物管理面板（HOM-68 v3 / 2026-06-15；HOM-203 性能改造）
    //
    // 历史背景：原方案只在 AI 设置里放一个「管理已生成的上下文 →」跳转按钮，把完整
    // 的输出目录 / 项目列表 / 单项删除面板放在 存储 Tab。dong4j 拍板把"精细化操作"
    // 集中到对应功能 Tab、把"全局汇总 + 一键清除"集中到 存储 Tab，因此本面板从
    // 存储 Tab 搬过来；存储 Tab 那边只保留汇总数字 + 行内"清理"按钮。
    //
    // **HOM-203（2026-06-16）改造**：用户反馈 576 个 repo 时本面板的 ForEach 渲染
    // 让设置页明显卡顿；同时 per-repo "打开 / 删除" 已被存储 Tab 的"全部清除"覆盖。
    // 决议：移除 ForEach + 单项 "打开 / 删除" 按钮；汇总统计源切到 `summary` 缓存
    // （`.starcat-summary.json`），UI 一次磁盘读取拿到 4 个数字，不再 O(n) 解析
    // metadata.json。详见 `RepoContextStorage` 的 HOM-203 注释。
    //
    // 视觉对照 `IntegrationSettingsView.codeFlowSection`，保持两类产物（CodeFlow /
    // RepoContextPacker）的 UI 节奏一致：
    //   1. 输出目录路径行 + 「选择目录 / 在 Finder 显示 / 重置默认」3 个按钮；
    //   2. 4 列汇总统计（项目数 / 占用 / 累计生成 / 最后生成）；
    //   3. 错误状态 / 空状态 提示。

    /// AI 代码上下文产物管理面板。
    @ViewBuilder
    private var repoContextManageStorageRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("ai.context.storage.outputDirectory", systemImage: "doc.text.magnifyingglass")
                    .font(.callout.weight(.medium))
                Text("ai.context.storage.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 8) {
                Text(aiContextStorage.outputDirectoryDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                Spacer()
                Button("ai.context.storage.choose") {
                    chooseAIContextOutputDirectory()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
                RevealInFinderIconButton(help: Text("ai.context.storage.revealHelp")) {
                    revealAIContextOutputDirectory()
                }
                .fixedSize()
                ResetIconButton(help: Text("ai.context.storage.resetHelp")) {
                    resetAIContextOutputDirectory()
                }
                .disabled(!aiContextStorage.hasCustomOutputDirectory)
                .fixedSize()
            }
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 18) {
                aiContextStat(titleKey: "ai.context.storage.statRepos",
                              value: "\(aiContextStorage.projectCount)")
                aiContextStat(titleKey: "ai.context.storage.statBytes",
                              value: ByteCountFormatter.string(fromByteCount: aiContextStorage.totalBytes, countStyle: .file))
                aiContextStat(titleKey: "ai.context.storage.statGenerations",
                              value: String(format: String.l10n("ai.context.storage.statGenerationsFormat"),
                                            aiContextStorage.totalGenerationCount))
                if let date = aiContextStorage.latestGeneratedAt {
                    aiContextStat(titleKey: "ai.context.storage.statLast",
                                  value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
            }
            .padding(.vertical, 8)

            // storage 内部抛错（bookmark 失效 / 目录权限丢失等）反映到 lastErrorMessage,
            // 持续显示直到下次 reload 成功。actionError（按钮触发的失败）走顶部 alert,
            // 两者职责分明：actionError = 短暂弹窗，lastErrorMessage = 持续状态。
            if let message = aiContextStorage.lastErrorMessage {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.vertical, 8)
            } else if aiContextStorage.projectCount == 0 {
                Divider()
                Text("ai.context.storage.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .disabled(!settings.aiRepoContextEnabled)
    }

    /// 4 列汇总统计中的单列（caption2 标题 + caption.weight(.medium) 数值）。
    /// 视觉与 `IntegrationSettingsView.stat(title:value:)` 对齐。
    private func aiContextStat(titleKey: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titleKey).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium))
        }
    }

    // MARK: - AI 代码上下文 storage action 入口

    /// 选择新的产物输出目录（NSOpenPanel）。失败走 aiContextActionError alert。
    private func chooseAIContextOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("ai.context.storage.choosePanelTitle")
        panel.prompt = String.l10n("ai.context.storage.choosePanelPrompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try aiContextStorage.setCustomOutputDirectory(url)
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func resetAIContextOutputDirectory() {
        do {
            try aiContextStorage.resetOutputDirectory()
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func revealAIContextOutputDirectory() {
        do {
            try aiContextStorage.revealOutputRoot()
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    // HOM-203：单项 reveal / delete 已经移除——repo 列表整体砍掉，"全部清除"
    // 在 设置 → 存储 Tab 已有入口，不再需要单项操作。`storage.revealProject`
    // 和 `storage.deleteProject` API 仍保留供未来使用 / 单测。

    /// Token 预算 Int↔Double 适配 binding。
    /// SwiftUI Slider 要求 `BinaryFloatingPoint` 值类型，但 `aiRepoContextTokenBudget` 是 Int
    /// （UserDefaults 直接 Int 持久化更直观，避免出现 `8000.0`）。这里在两端之间做转换：
    ///   - get：Int → Double（无损扩展）
    ///   - set：Double → Int（`rounded()` 保证步进对齐到整 2000）
    private var tokenBudgetBinding: Binding<Double> {
        Binding(
            get: { Double(self.settings.aiRepoContextTokenBudget) },
            set: { newValue in
                self.settings.aiRepoContextTokenBudget = Int(newValue.rounded())
            }
        )
    }

    /// 源码 ZIP 上限 Int↔Double 适配。setter 再做一次范围钳制，防止键盘辅助操作或未来
    /// 调整 Slider 范围时把底层 Packer 无法接受的值写进 UserDefaults。
    private var maximumArchiveSizeBinding: Binding<Double> {
        Binding(
            get: { Double(self.settings.aiRepoContextMaximumArchiveMB) },
            set: { newValue in
                let range = AppSettings.aiRepoContextMaximumArchiveMBRange
                self.settings.aiRepoContextMaximumArchiveMB = min(
                    max(Int(newValue.rounded()), range.lowerBound),
                    range.upperBound
                )
            }
        )
    }

    /// 总开关 Bool binding。AISettingsTab 没用 `@Bindable var settings = settings`（与
    /// SettingsView.generalTab 不同），所以子项 Toggle 不能直接 `$settings.xxx`，必须走
    /// 自定义 binding（与 `autoPrefetchBinding` 同款）。
    private var repoContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.aiRepoContextEnabled },
            set: { self.settings.aiRepoContextEnabled = $0 }
        )
    }

    /// Tier 1 行数 Int binding。
    ///
    /// TextField 写入时统一钳制 40...200，避免用户输入越界值进入 UserDefaults。
    private var repoContextTier1MaxLinesBinding: Binding<Int> {
        Binding(
            get: { self.settings.aiRepoContextTier1MaxLines },
            set: { self.settings.aiRepoContextTier1MaxLines = min(max($0, 40), 200) }
        )
    }

    // MARK: - Actions

    /// 写入 `selectedProfileID` 的统一入口。
    /// nil → 持久化层写空串哨兵；非 nil → 直接写入 ID。
    /// 集中走这个 helper 是为了让"空串 ↔ nil"语义不要散落到 4 个赋值点。
    private func setSelectedProfileID(_ id: String?) {
        AppLog.ai.debug("[AISettings] setSelectedProfileID(\(id ?? "nil", privacy: .public)) prev=\(self.settings.aiSettingsSelectedProfileID, privacy: .public)")
        settings.aiSettingsSelectedProfileID = id ?? ""
    }

    private func ensureSelection() {
        if selectedProfileID == nil || pickerProfiles.allSatisfy({ $0.id != selectedProfileID }) {
            // 从未选过 / 指向已删 profile 时优先回落到本地 AI（首启动默认服务商）。
            let fallback = pickerProfiles.first(where: { $0.provider == .localAI })?.id
                ?? pickerProfiles.first?.id
            setSelectedProfileID(fallback)
        }
    }

    private func loadAPIKeys() {
        for profile in settings.aiProviderProfiles {
            apiKeys[profile.id] = (try? KeychainManager.shared.loadAIKey(forProvider: profile.id)) ?? ""
        }
    }

    @MainActor
    private func beginCCSwitchImport() {
        ccSwitchImportError = nil
        if DistributionChannel.current.isDirect,
           let url = POSIXHome.ccSwitchDefaultDatabase,
           FileManager.default.isReadableFile(atPath: url.path) {
            openCCSwitchFile(url)
            return
        }
        presentCCSwitchOpenPanel()
    }

    @MainActor
    private func presentCCSwitchOpenPanel() {
        let panel = NSOpenPanel()
        let defaultPath = POSIXHome.ccSwitchDefaultDatabase?.path ?? "~/.cc-switch/cc-switch.db"
        panel.message = String(format: String.l10n("settings.ai.provider.importCCSwitch.panelMessage"), defaultPath)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "db"),
            UTType(filenameExtension: "sqlite"),
            UTType(filenameExtension: "sqlite3"),
            UTType(filenameExtension: "sql")
        ].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openCCSwitchFile(url)
    }

    @MainActor
    private func openCCSwitchFile(_ url: URL) {
        do {
            let rows = try CCSwitchConfigStore.open(url: url)
            let preview = CCSwitchProviderMapper.preview(
                rows: rows,
                sourcePath: url.path,
                anthropicAvailable: CCSwitchProviderMapper.isAnthropicAdapterAvailable
            )
            ccSwitchImportSession = CCSwitchImportSession(preview: preview)
        } catch {
            ccSwitchImportError = error.localizedDescription
        }
    }

    @MainActor
    private func importCCSwitchCandidates(
        _ candidates: [CCSwitchImportCandidate],
        progress: @MainActor (Int, Int, String) -> Void
    ) async -> CCSwitchImportOutcome {
        var succeeded: [CCSwitchImportResultRow] = []
        var failed: [CCSwitchImportResultRow] = []
        var existingNames = settings.aiProviderProfiles.map(\.displayName)
        var cancelled = false

        for (offset, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            progress(offset + 1, candidates.count, candidate.displayName)
            let displayName = CCSwitchProviderMapper.uniquedDisplayName(
                candidate.displayName,
                existing: existingNames
            )
            existingNames.append(displayName)
            let profile = AIProviderProfile(
                id: UUID().uuidString,
                provider: candidate.provider,
                displayName: displayName,
                baseURL: candidate.baseURL,
                isEnabled: false,
                lastTestStatus: .notTested
            )
            var profiles = settings.aiProviderProfiles
            profiles.append(profile)
            settings.aiProviderProfiles = profiles
            do {
                try persistAPIKey(
                    candidate.apiKey,
                    forProvider: profile.id,
                    allowsEmpty: profile.provider.allowsEmptyAPIKey
                )
                apiKeys[profile.id] = candidate.apiKey
            } catch {
                failed.append(CCSwitchImportResultRow(
                    id: profile.id,
                    displayName: displayName,
                    profileID: profile.id,
                    succeeded: false,
                    statusText: error.localizedDescription
                ))
                AppLog.ai.error("CC Switch import persist failed appType=\(candidate.appType, privacy: .public) provider=\(candidate.provider.rawValue, privacy: .public)")
                continue
            }

            await testAndFetchModels(profile)
            let updated = settings.aiProviderProfiles.first { $0.id == profile.id } ?? profile
            let ok: Bool
            if case .success = updated.lastTestStatus {
                ok = true
            } else {
                ok = false
            }
            let row = CCSwitchImportResultRow(
                id: profile.id,
                displayName: displayName,
                profileID: profile.id,
                succeeded: ok,
                statusText: updated.lastTestStatus.displayText
            )
            if ok {
                succeeded.append(row)
            } else {
                failed.append(row)
            }
            AppLog.ai.info("CC Switch import appType=\(candidate.appType, privacy: .public) provider=\(candidate.provider.rawValue, privacy: .public) success=\(ok, privacy: .public)")
        }

        if Task.isCancelled {
            cancelled = true
        }
        return CCSwitchImportOutcome(succeeded: succeeded, failed: failed, cancelled: cancelled)
    }

    @MainActor
    private func testAndFetchModels(_ profile: AIProviderProfile) async {
        isTestingProfileID = profile.id
        defer { isTestingProfileID = nil }

        let testingKey = apiKey(for: profile)
        do {
            let verified = try await AIProviderConnectionVerifier.verify(
                profile: profile,
                apiKey: testingKey,
                referencedModelNames: referencedModelNames(for: profile.id)
            )

            try persistAPIKey(testingKey, forProvider: profile.id, allowsEmpty: profile.provider.allowsEmptyAPIKey)

            updateProfile(profile.id) { current in
                current = verified
            }
            apiKeys[profile.id] = testingKey
            repairTasksAfterProfileChange()
        } catch {
            updateProfile(profile.id) { current in
                current.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
                current.lastTestStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func persistAPIKey(_ rawKey: String, forProvider profileID: String, allowsEmpty: Bool) throws {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !allowsEmpty {
            throw AIClientError.missingAPIKey
        }
        if trimmed.isEmpty {
            try KeychainManager.shared.deleteAIKey(forProvider: profileID)
        } else {
            try KeychainManager.shared.storeAIKey(trimmed, forProvider: profileID)
        }
    }

    private func apiKey(for profile: AIProviderProfile) -> String {
        apiKeys[profile.id, default: ""]
    }

    private func restoreDefaultPrompt(_ task: AIModelTask) {
        // 2026-09-11：翻译任务的 Prompt（分段 / 全文）已迁入「翻译服务」设置页，
        // 这里只剩非翻译任务的恢复默认；`.translation` 分支仅为 switch 穷尽性保留。
        updateTask(task) { config in
            switch task {
            case .summary:
                config.prompt = AIDefaultPrompts.summary
            case .tags:
                config.prompt = AIDefaultPrompts.tags
            case .embedding:
                config.prompt = AIDefaultPrompts.embedding
            case .chat:
                config.prompt = AIDefaultPrompts.chat
            case .translation:
                // UI 不再出现翻译任务（已迁「翻译服务」页）；仅为穷尽性保留。
                config.prompt = AIDefaultPrompts.translation
            }
        }
    }

    // MARK: - Bindings

    private var selectedProfileBinding: Binding<String?> {
        Binding(
            get: { selectedProfileID },
            set: { newSelection in
                // Picker 刷新可能回写 nil 或同值；只有真正选择另一项才持久化。
                guard let newSelection, newSelection != selectedProfileID else { return }
                setSelectedProfileID(newSelection)
            }
        )
    }

    private func modelEnabledBinding(_ profileID: String, _ modelID: String) -> Binding<Bool> {
        Binding(
            get: { model(profileID: profileID, modelID: modelID)?.isEnabled ?? false },
            set: { enabled in
                // 取消勾选前先记下是否被任务引用：未引用时不必跑 repair（会连写 5 份 task JSON）。
                guard model(profileID: profileID, modelID: modelID)?.isEnabled != enabled else { return }
                let modelName = model(profileID: profileID, modelID: modelID)?.name
                let needsTaskRepair = !enabled && isModelReferencedByAnyTask(
                    providerID: profileID,
                    modelName: modelName
                )
                updateModel(profileID: profileID, modelID: modelID) { model in
                    model.isEnabled = enabled
                }
                if needsTaskRepair {
                    repairTasksAfterProfileChange()
                }
            }
        )
    }

    /// 任一任务是否正指向该 provider + 模型（自定义模型名不算「目录勾选」引用）。
    private func isModelReferencedByAnyTask(providerID: String, modelName: String?) -> Bool {
        guard let modelName, !modelName.isEmpty else { return false }
        return AIModelTask.allCases.contains { task in
            let config = taskConfig(task)
            guard config.providerID == providerID, !config.useCustomModel else { return false }
            return config.modelID == modelName
        }
    }

    /// 合并 / 消毒大目录时保住任务仍在用的模型名（含自定义名称，避免关掉正在跑的配置）。
    private func referencedModelNames(for profileID: String) -> Set<String> {
        Set(AIModelTask.allCases.compactMap { task in
            let config = taskConfig(task)
            guard config.providerID == profileID else { return nil }
            let name = config.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })
    }

    private func modelCapabilityBinding(_ profileID: String, _ modelID: String) -> Binding<AIModelCapability> {
        Binding(
            get: { model(profileID: profileID, modelID: modelID)?.capability ?? .unknown },
            set: { capability in
                // Picker 出现时可能把当前值再 set 一遍；无变化就不要写回整个 profiles 数组。
                guard model(profileID: profileID, modelID: modelID)?.capability != capability else { return }
                updateModel(profileID: profileID, modelID: modelID) { model in
                    model.capability = capability
                }
                repairTasksAfterProfileChange()
            }
        )
    }

    /// 菜单身份同时包含服务商和模型；自定义项与不可用项只用于显示当前值。
    private func taskModelChoice(_ task: AIModelTask) -> TaskModelChoice {
        let config = taskConfig(task)
        return TaskModelChoice(
            providerID: config.providerID,
            modelName: config.useCustomModel ? config.customModelName : config.modelID,
            isCustom: config.useCustomModel
        )
    }

    /// 合并下拉的一次选择等价于原先先选服务商再选模型，但只写入一次任务配置。
    private func taskModelChoiceBinding(_ task: AIModelTask) -> Binding<TaskModelChoice> {
        Binding(
            get: { taskModelChoice(task) },
            set: { choice in
                guard !choice.isCustom,
                      eligibleVerifiedProfiles(for: task).contains(where: { $0.id == choice.providerID }),
                      enabledModels(providerID: choice.providerID, capability: task.requiredCapability)
                        .contains(where: { $0.name == choice.modelName }) else { return }
                settings.selectLocalAIModel(named: choice.modelName, providerID: choice.providerID)
                updateTask(task) { config in
                    if config.providerID != choice.providerID,
                       let first = enabledModels(providerID: choice.providerID, capability: task.requiredCapability).first {
                        // 原服务商切换会预填首个模型名称；同服务商切换仍保留手填文本。
                        config.customModelName = first.name
                    }
                    config.providerID = choice.providerID
                    config.modelID = choice.modelName
                    config.useCustomModel = false
                }
            }
        )
    }

    private func taskCustomEnabledBinding(_ task: AIModelTask) -> Binding<Bool> {
        Binding(
            get: { taskConfig(task).useCustomModel },
            set: { enabled in
                updateTask(task) { config in
                    config.useCustomModel = enabled
                    // 仅「开启且输入为空」时用当前列表模型预填；关闭开关绝不清空文本。
                    if enabled, config.customModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        config.customModelName = config.modelID
                    }
                }
            }
        )
    }

    private func taskCustomModelBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).customModelName },
            set: { value in updateTask(task) { $0.customModelName = value } }
        )
    }

    /// HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
    /// 模型粒度参数 binding。包给 `AIModelListView` 让齿轮按钮 popover 写回。
    /// 返回的是可空 binding——`nil` 表示"未覆盖，走 capability 默认"，popover
    /// 内部会在第一次实际改值时把它 materialize 成非 nil 值。
    private func modelParametersBinding(_ profileID: String, _ modelID: String) -> Binding<AIModelParameters?> {
        Binding(
            get: { model(profileID: profileID, modelID: modelID)?.parameters },
            set: { newParameters in
                updateModel(profileID: profileID, modelID: modelID) { model in
                    model.parameters = newParameters
                }
            }
        )
    }

    // 2026-09-11：翻译 Prompt（分段 / 全文）的编辑入口已迁入「翻译服务」设置页，
    // 这里的 binding 只服务其余任务。
    private func promptSystemBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).prompt.systemPrompt },
            set: { value in updateTask(task) { $0.prompt.systemPrompt = value } }
        )
    }

    private func promptUserBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).prompt.userPromptTemplate },
            set: { value in updateTask(task) { $0.prompt.userPromptTemplate = value } }
        )
    }

    // MARK: - State helpers

    private var verifiedProfiles: [AIProviderProfile] {
        settings.aiProviderProfiles.filter(\.isVerifiedConfiguration)
    }

    /// 服务商 Picker 的可选项：已验证 profile + 内置本地 AI（未下载模型时也显示，
    /// 选中后由「本地 AI 模型」区引导下载）。首启动默认选中 Local AI（dong4j 2026-09-12）。
    private var pickerProfiles: [AIProviderProfile] {
        settings.aiProviderProfiles.filter { $0.isVerifiedConfiguration || $0.provider == .localAI }
    }

    /// 任务下拉只显示具备对应协议端点的已验证 Provider。
    ///
    /// 模型 capability 来自名称推断或用户标注，不能替代 Provider 端点能力；尤其
    /// OrcaRouter 的 `/v1/models` 会返回 Chat/多媒体模型，但没有 `/v1/embeddings`。
    private func eligibleVerifiedProfiles(for task: AIModelTask) -> [AIProviderProfile] {
        verifiedProfiles.filter { profile in
            task.requiredCapability != .embedding || profile.provider.supportsEmbeddingEndpoint
        }
    }

    private var activeProfile: AIProviderProfile? {
        selectedProfile
    }

    private var selectedProfile: AIProviderProfile? {
        guard let selectedProfileID else { return pickerProfiles.first }
        return pickerProfiles.first { $0.id == selectedProfileID }
    }

    private func profile(_ id: String) -> AIProviderProfile? {
        settings.aiProviderProfiles.first { $0.id == id }
    }

    private func model(profileID: String, modelID: String) -> AIModelDescriptor? {
        profile(profileID)?.models.first { $0.id == modelID }
    }

    private func updateProfile(_ id: String, mutate: (inout AIProviderProfile) -> Void) {
        var profiles = settings.aiProviderProfiles
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&profiles[index])
        settings.aiProviderProfiles = profiles
    }

    private func updateModel(
        profileID: String,
        modelID: String,
        mutate: (inout AIModelDescriptor) -> Void
    ) {
        updateProfile(profileID) { profile in
            guard let index = profile.models.firstIndex(where: { $0.id == modelID }) else { return }
            mutate(&profile.models[index])
        }
    }

    private func taskConfig(_ task: AIModelTask) -> AIModelTaskConfiguration {
        let config: AIModelTaskConfiguration
        switch task {
        case .summary:     config = settings.aiSummaryTask
        case .tags:        config = settings.aiTagsTask
        case .embedding:   config = settings.aiEmbeddingTask
        case .translation: config = settings.aiTranslationTask
        case .chat:        config = settings.aiChatTask
        }
        return settings.resolvedAITask(config, type: task.requiredCapability == .embedding ? .embedding : .llm)
    }

    private func updateTask(_ task: AIModelTask, mutate: (inout AIModelTaskConfiguration) -> Void) {
        var config = taskConfig(task)
        mutate(&config)
        switch task {
        case .summary:
            settings.aiSummaryTask = config
        case .tags:
            settings.aiTagsTask = config
        case .embedding:
            settings.aiEmbeddingTask = config
        case .translation:
            settings.aiTranslationTask = config
        case .chat:
            settings.aiChatTask = config
        }
    }

    // 统一菜单仍逐服务商过滤，选择身份使用 TaskModelChoice，避免跨服务商同名模型串选。
    private func enabledModels(providerID: String, capability: AIModelCapability) -> [AIModelDescriptor] {
        guard let profile = profile(providerID), profile.isVerifiedConfiguration else { return [] }
        guard capability != .embedding || profile.provider.supportsEmbeddingEndpoint else { return [] }
        return profile.models.filter {
            $0.isEnabled && ($0.capability == capability || $0.capability == .unknown)
        }
    }

    private func repairTasksAfterProfileChange() {
        for task in AIModelTask.allCases {
            let config = taskConfig(task)
            // 明确选中的本地模型未下载/已卸载时应提示安装，不能静默换成远程服务商。
            if profile(config.providerID)?.provider == .localAI { continue }
            let models = enabledModels(providerID: config.providerID, capability: task.requiredCapability)
            let eligibleProfiles = eligibleVerifiedProfiles(for: task)
            let currentProfileIsEligible = eligibleProfiles.contains { $0.id == config.providerID }
            if !currentProfileIsEligible || (!config.useCustomModel && models.allSatisfy { $0.name != config.modelID }) {
                let fallbackProfile = eligibleProfiles.first
                updateTask(task) { updated in
                    updated.providerID = fallbackProfile?.id ?? ""
                    if let first = fallbackProfile.flatMap({ enabledModels(providerID: $0.id, capability: task.requiredCapability).first }) {
                        updated.modelID = first.name
                        updated.customModelName = first.name
                        updated.useCustomModel = false
                    } else {
                        updated.modelID = ""
                        updated.customModelName = ""
                        updated.useCustomModel = true
                    }
                }
            }
        }
    }

}

#Preview {
    AISettingsTab()
        .environment(AppSettings(defaults: .standard))
        .frame(width: 720, height: 860)
}

/// Provider 配置区专用单行输入框。
///
/// HOM-AIPROVIDERS-DRAFT-DISCARD-2026-06-06 (dong4j 反馈):
/// SwiftUI 桥接 `NSWindow.willCloseNotification` 的窄范围监听器。
///
/// 用途:在 Settings 窗口真正关闭时通知 AI Tab 丢弃未完成草稿。
///
/// 关键约束 / 已踩过的坑:
/// - **必须把 observer 的 `object` 限定为 self.window**,而不是 nil。
///   nil 会让 observer 监听到 app 任意 NSWindow 关闭事件——主窗口关闭也会
///   误清掉 AI Tab 的 draft,把"打开 Starcat → 配 AI → 关主窗 → 重开 App"
///   的草稿连续性弄丢。
/// - **必须在 `viewDidMoveToWindow` 注册/反注册** 而不是 init / makeNSView:
///   NSViewRepresentable 创建 NSView 时尚未挂到窗口,self.window 是 nil;
///   `viewDidMoveToWindow` 在 view 加入 / 离开 window hierarchy 时都会触发,
///   是注册 window-scoped observer 的正确时机。
/// - **`[weak self]`** 防止 observer 强引用 self 造成 ListenerView 在窗口
///   关闭后还活着、漏掉 deinit。
/// - **不会被切 Tab 触发**:NSTabView 切 tab 是 NSTabView 内部行为,不动
///   NSWindow 生命周期,所以这个 observer 在 Settings 内部切 Tab 时静默不工作,
///   不会误清 draft。这是为什么这里坚持用 NSWindow 通知而不是 SwiftUI
///   `.onDisappear`(macOS 15 上 onDisappear 切 Tab 触发行为不一致)。
private struct SettingsWindowCloseListener: NSViewRepresentable {

    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ListenerView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI 每次 body 重新执行时会创建新的 onClose 闭包(它捕获的是
        // 当前 body 调用时的 self snapshot,确保闭包内访问 @State 拿到的
        // 是最新存储引用),这里把新闭包刷新到 ListenerView。
        (nsView as? ListenerView)?.onClose = onClose
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let view = nsView as? ListenerView else { return }
        view.onClose = nil
        view.removeObserver()
    }

    private final class ListenerView: NSView {
        var onClose: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObserver()
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // queue 已固定为 main；同步失效新增会话，防止排队的网络成功回调抢先保存。
                MainActor.assumeIsolated {
                    self?.onClose?()
                }
            }
        }

        @MainActor
        fileprivate func removeObserver() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }
    }
}
