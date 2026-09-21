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

    @State private var draftProfile: AIProviderProfile?
    @State private var draftAPIKey: String = ""
    @State private var apiKeys: [String: String] = [:]
    @State private var isTestingProfileID: String?
    @State private var keyError: String?
    @State private var promptTask: AIModelTask = .summary
    /// Prompt 区「可用占位符」popover；切换任务时关闭，避免旧任务说明残留。
    @State private var isPromptPlaceholderPopoverPresented = false

    /// HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12 (dong4j 反馈)：
    /// 删除服务商需要二次确认。删除会同步删 profile + Keychain key + 修复
    /// 任务绑定（`repairTasksAfterProfileChange`），属于不可逆破坏性操作，
    /// 走 `.confirmationDialog` 拦一道。`pendingDeleteProfileID` 持有待删
    /// 目标的 ID 而非整个 profile，避免 dialog 弹起期间 `verifiedProfiles`
    /// 数组变化导致引用悬空（异步刷新 / @AppStorage 写回都可能触发刷新）。
    @State private var pendingDeleteProfileID: String?

    /// HOM-68 follow-up v7 (dong4j 反馈 2026-06-05 23:20)：
    /// "默认设置"（原"模型设置"）也改成 tab 样式，4 个任务（summary/tags/
    /// embedding/translation）共用一行 Provider+模型 picker。和 parameterTask /
    /// promptTask 分开，让用户在不同区切换任务时互不干扰（设默认时看的是
    /// summary，但调参数时可能在调 tags，强同步会反直觉）。
    @State private var taskModelTask: AIModelTask = .summary

    // HOM-68 follow-up v9：原"模型参数"区已迁到"已发现模型"每行的齿轮 popover
    // （模型粒度，不再按任务），不再需要 isParametersExpanded SceneStorage。
    private static let taskModelsSettingsAnchor = "settings.ai.taskModels"
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

    /// AI 代码上下文 storage 操作失败时弹 alert 用。和 `keyError` 等并列各管一摊。
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

    /// Intel 免费用户仍可配置原本位于“集成”的联网搜索；仅模型、自动化、语义
    /// 索引和仓库上下文继续遵守既有 Pro / Apple Silicon Local AI 门控。
    private var hasAIConfigurationAccess: Bool {
        dependencies.entitlementGate.isProUser || LocalAIHardwareSupport.isLocalAIAvailable
    }

    @ViewBuilder
    var body: some View {
        // AI 服务是 Direct / StoreKit 共享的 Pro 能力，必须读取聚合后的业务门控；
        // 直接读取 SubscriptionManager 会把 Direct License 用户误判为未开通。
        // 本地 AI 免费（dong4j 2026-09-12）：Apple Silicon 上免费用户也必须能进入
        // 本页配置并下载本地模型；远程 provider 的消费仍由 EntitlementGate 在调用点拦截，
        // 设置页只是配置面。Intel Mac 维持整页锁定。
        if page == .externalSearch || hasAIConfigurationAccess {
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
                providerSection
                // 本地模型只在选中 Starcat Local AI 时出现，避免远程供应商页面
                // 同时展示无关下载项；模型与任务绑定按依赖顺序从上到下排列。
                if LocalAIHardwareSupport.isLocalAIAvailable, activeProfile?.provider == .localAI {
                    LocalAIModelsSection(settings: dependencies.settings)
                }
                enabledModelsSection
                taskModelsSection
                    .id(Self.taskModelsSettingsAnchor)
                // Prompt 有完整默认值，不属于首次配置必填项，继续放在模型页末尾。
                promptSection
            case .automation:
                // 两项都消费上游模型配置，但彼此不是父子能力，保留独立顶级 Section。
                autoTidySection
                githubListGroupingSection
            case .indexAndContext:
                aiIndexSection
                    .id(Self.aiIndexSettingsAnchor)
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
        .formStyle(.grouped)
        // Placeholders popover 锚在 Prompt 区按钮上：Form 一滚就关，避免锚点滚走后浮层悬空。
        .onScrollPhaseChange { _, newPhase in
            guard newPhase != .idle else { return }
            isPromptPlaceholderPopoverPresented = false
        }
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
            // 入口语义是“配置向量模型”：直接切换到向量化任务并定位常驻分组。
            taskModelTask = .embedding
            DispatchQueue.main.async {
                proxy.scrollTo(Self.taskModelsSettingsAnchor, anchor: .top)
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
        // HOM-AIPROVIDERS-DRAFT-DISCARD-2026-06-06 (dong4j 反馈):
        // SwiftUI macOS Settings scene 关闭窗口后不一定销毁 view 树,
        // `@State` 的 `draftProfile` 会残留——用户点 "+" 号生成空草稿、
        // 没改没测就关闭 Settings,下次再开 Settings 仍看到这个空草稿,
        // 违反"未完成配置在关闭设置后不保存"原则。
        //
        // 修法:监听 `NSWindow.willCloseNotification`,在 Settings 窗口真正
        // 关闭时丢弃 draft 三件套(profile / API key / keyError)。
        // **不用 `.onDisappear`**:macOS TabView 切 Tab 时 onDisappear 触发
        // 行为不一致(macOS 15 实测可能误触发),会误清用户在 AI Tab 半改完
        // 切到 General Tab 又切回来时的输入。`NSWindow.willCloseNotification`
        // 只在窗口真正关闭时触发,切 Tab 不动 NSWindow 生命周期,精准。
        .background(SettingsWindowCloseListener {
            // 只清未通过测试的 draft;通过测试的 draft 在 testAndFetchModels
            // 成功路径里已被晋升为 verified profile 并把 draftProfile 置 nil,
            // 这里看到的 draftProfile != nil 全是"未完成"草稿。
            AppLog.ai.debug("[AISettings] SettingsWindowCloseListener.onClose fired draftID=\(self.draftProfile?.id ?? "nil", privacy: .public)")
            discardDraft()
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

    private var providerSection: some View {
        Section {
            // 与下方「显示名称」同一套：左 label 列 + 垂直居中。
            // 不用 LabeledContent——Form 会按首行基线排 label，右侧 28pt 按钮一高，
            // 标题就会看起来偏上。下拉靠右，贴着导入 / + / 删除。
            HStack(alignment: .center, spacing: ProviderFieldLayout.rowSpacing) {
                Text("settings.ai.provider.pickerLabel")
                    .font(.body)
                    .frame(width: ProviderFieldLayout.labelWidth, alignment: .leading)
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

                ImportIconButton(help: Text("settings.ai.provider.importCCSwitch.help")) {
                    beginCCSwitchImport()
                }
                .disabled(draftProfile != nil || isTestingProfileID != nil)

                AddIconButton(help: Text("settings.ai.provider.addHelp")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        beginDraft(provider: .openAICompatible)
                    }
                }
                .disabled(draftProfile != nil)

                if draftProfile != nil {
                    CancelIconButton(
                        help: Text(
                            isAddingNewProviderDraft
                                ? "settings.ai.provider.discardDraft.addHelp"
                                : "settings.ai.provider.discardDraft.editHelp"
                        ),
                        font: SettingsIconMetrics.standardGlyph,
                        frameSize: SettingsIconMetrics.actionFrameSize
                    ) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            discardDraft()
                        }
                    }
                    .disabled(isTestingProfileID != nil)
                } else {
                    DestructiveIconButton(
                        help: Text("settings.ai.provider.deleteHelp"),
                        font: SettingsIconMetrics.standardGlyph,
                        frameSize: SettingsIconMetrics.actionFrameSize
                    ) {
                        pendingDeleteProfileID = selectedProfileID
                    }
                    .disabled(selectedProfile == nil || selectedProfile?.provider == .localAI)
                }
            }

            // HOM-AIPROVIDERS-HIDE-PROVIDER-2026-06-12 (dong4j 反馈)：
            // Provider 下拉只在「点 + 进入新增草稿」时显示。背景：之前两个下拉常驻
            //   1) 「服务商配置」= 已验证 profile 切换
            //   2) 「Provider」    = 选 provider 类型 / 隐式重建草稿
            // 两个下拉语义不同但视觉同形（都是 menu picker），新用户进设置页一眼看
            // 不出谁是「我现在在看哪个 profile」、谁是「我要新建」。更糟的是 Provider
            // 下拉直接切类型就会重建草稿（`supportedProviderBinding.set` 调
            // `beginDraft`），与右上角 `+` 按钮形成两个新增入口，违反「+ 是新增唯一
            // 入口」的产品意图。
            //
            // 修法：Provider 下拉用 `if draftProfile != nil` 包裹，常态隐藏；只在点
            // `+`（→ beginDraft → draftProfile != nil）后随输入区一起出现。这样信息
            // 架构变成「常态只显示当前 profile / 点 + 进入新增模式才显示类型选择」，
            // 与 macOS 系统设置「网络 → +」的交互节奏一致。
            //
            // Provider 切换仍走原 `supportedProviderBinding`（重建草稿，丢弃同一草稿
            // 内已输入的 displayName/baseURL/apiKey）。这是合理的——切类型本质就是
            // 「换底子」，不同 provider 的默认 baseURL 完全不同，保留旧值会更困惑。
            //
            // transition 用 `.opacity` + 默认 spring，让出现/消失自然过渡，避免 Form
            // 里某行突然蹦出来。
            //
            // 边界场景：用户在已验证 profile 上修改 displayName/baseURL/apiKey 时，
            // `editableProfileTextBinding` 会调 `beginDraft(from: current)` 把它提升为
            // 草稿 → 这里 Provider 行也会跟着出现。这是预期行为：① 与「新增模式」UI
            // 统一（draft != nil 都显示）；② 用户编辑时本来就可以切类型（如发现 Base
            // URL 错了想换个 provider），保留这个能力；③ 用户不点 Provider 就不会
            // 影响输入，干扰极小。
            if draftProfile != nil {
                Picker("Provider", selection: supportedProviderBinding) {
                    // 按硬件能力过滤：Intel Mac 不提供本地 AI 选项。
                    ForEach(AIServiceProvider.userSelectableCases) { provider in
                        Label {
                            Text(provider.displayName)
                        } icon: {
                            AIProviderIconView(provider: provider, size: 14)
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

            if let profile = activeProfile {
                if profile.provider == .localAI {
                    // 内置本地 AI：无 Key / 无 Base URL 可填，也不走「测试并获取模型」。
                    // 下载模型在下方「本地 AI 模型」区；此处只给一句引导。
                    Text("settings.localai.provider.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    providerInputRows(profile)

                    if profile.provider == .anthropic {
                        // 两条 caption 收进同一 Form 行，避免 grouped Form 给每句各垫一行高。
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                SettingsCaptionASCIILinks.attributedString(
                                    from: String.l10n("settings.ai.provider.anthropic.baseURLHint")
                                )
                            )
                            .tint(.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                            Text("settings.ai.provider.anthropic.embeddingUnsupported")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack {
                        Text(profile.lastTestStatus.displayText)
                            .font(.caption)
                            .foregroundStyle(statusTint(profile.lastTestStatus))
                            .lineLimit(2)
                            .truncationMode(.tail)

                        Spacer(minLength: 12)

                        Button {
                            Task { await testAndFetchModels(profile) }
                        } label: {
                            if isTestingProfileID == profile.id {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.small)
                                    Text("settings.ai.provider.testButton")
                                }
                            } else {
                                Label("settings.ai.provider.testButton", systemImage: "network")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isTestingProfileID != nil || !canTest(profile))
                    }
                }

                if let keyError {
                    Text(keyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            SettingsSectionHeader(
                "settings.ai.provider.sectionTitle",
                systemImage: "server.rack"
            )
        } footer: {
            Text("settings.ai.provider.sectionFooter")
        }
    }

    private var enabledModelsSection: some View {
        // “模型与供应商”已经是独立一级页面；模型列表常驻展示，避免再套一层折叠。
        Section {
            Group {
                if let profile = selectedProfile {
                    if profile.models.isEmpty {
                        Text("settings.ai.discoveredModels.empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        AIModelListView(
                            profile: profile,
                            enabledBinding: { model in modelEnabledBinding(profile.id, model.id) },
                            capabilityBinding: { model in modelCapabilityBinding(profile.id, model.id) },
                            parametersBinding: { model in modelParametersBinding(profile.id, model.id) }
                        )
                        .id(profile.id)
                    }
                }
            }
        } header: {
            SettingsSectionHeader(
                "settings.ai.discoveredModels.title",
                systemImage: "list.bullet.rectangle"
            )
        }
    }

    // MARK: - Tasks

    private var taskModelsSection: some View {
        // 配置页按依赖顺序常驻展示任务模型；深链接只需切换任务并滚动定位。
        Section {
            // 等宽铺满：系统 segmented 按文案 intrinsic 定宽，中文短/英文长会两套布局；
            // EqualWidthSegmentedControl 按父宽均分，中英文同一套整行样式。
            VStack(alignment: .leading, spacing: 0) {
                EqualWidthSegmentedControl(
                    items: AIModelTask.aiSettingsPageTasks,
                    selection: $taskModelTask,
                    title: { LocalizedStringKey($0.displayNameKey) }
                )
                .accessibilityLabel("settings.ai.task.pickerLabel")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)

                Divider()

                taskModelRow(taskModelTask)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            SettingsSectionHeader(
                "settings.ai.taskModels.title",
                systemImage: "slider.horizontal.3"
            )
        }
    }

    private func taskModelRow(_ task: AIModelTask) -> some View {
        // 2026-07-19：自定义模型改为「左 label + 右 Switch」；开启后下一行出加长输入框。
        // 关闭开关只改 useCustomModel，不清空 customModelName。
        let currentProviderID = taskConfig(task).providerID
        let useCustom = taskConfig(task).useCustomModel
        let availableModels = enabledModels(
            providerID: currentProviderID,
            capability: task.requiredCapability
        )
        let availableProfiles = eligibleVerifiedProfiles(for: task)

        return VStack(alignment: .leading, spacing: 0) {
            taskModelTrailingRow(label: "settings.ai.task.providerLabel") {
                // HOM-AIPROVIDERS-2026-06-06：挂 provider logo，自定义 profile 名时仍能辨认服务商。
                Picker("settings.ai.task.providerLabel", selection: taskProviderBinding(task)) {
                    ForEach(availableProfiles) { profile in
                        Label {
                            Text(profile.displayName)
                        } icon: {
                            AIProviderIconView(provider: profile.provider, size: 14)
                        }
                        .tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Divider()

            taskModelTrailingRow(label: "settings.ai.task.modelLabel") {
                Picker("settings.ai.task.modelLabel", selection: taskModelBinding(task)) {
                    if availableModels.isEmpty {
                        Text("settings.ai.task.noAvailableModel")
                            .tag("")
                    } else {
                        ForEach(availableModels) { model in
                            Text(AnthropicModelCatalog.displayName(forAPIID: model.name)).tag(model.name)
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Divider()

            // 与「标签分类」同款：用 Toggle 自带的左标题 + 右开关，不要再套
            // labelsHidden + 手写 HStack——后者在 Form 里会把开关撑得异常大、行高留白。
            Toggle("settings.ai.task.customModelLabel", isOn: taskCustomEnabledBinding(task))
                .toggleStyle(.switch)
                .padding(.vertical, 8)

            if useCustom {
                Divider()
                taskModelTrailingRow(label: "settings.ai.task.customModelPlaceholder") {
                    TextField("", text: taskCustomModelBinding(task))
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 设置行：左侧 label、右侧控件（一左一右）。
    private func taskModelTrailingRow<Content: View>(
        label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
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

    /// 显示名称 / Base URL / API Key：跟「服务」页同一套行高。
    ///
    /// 旧实现把三行锁成 52pt 再塞进一个固定高度 VStack，Form 行被撑得比系统
    /// grouped 行高一倍。`SingleLineTextField` 已压低 hugging，超长 URL 不会再
    /// 把行顶换行，因此改回独立 Form 行，高度交给 22pt bezel 字段。
    private enum ProviderFieldLayout {
        static let labelWidth: CGFloat = 96
        static let fieldHeight: CGFloat = 22
        static let rowSpacing: CGFloat = 8
    }

    @ViewBuilder
    private func providerInputRows(_ profile: AIProviderProfile) -> some View {
        providerInputRow(label: "settings.ai.provider.displayName") {
            SingleLineTextField(text: editableProfileTextBinding(keyPath: \.displayName))
                .accessibilityLabel("settings.ai.provider.displayName")
        }
        providerInputRow(label: "Base URL") {
            SingleLineTextField(text: editableProfileTextBinding(keyPath: \.baseURL))
                .accessibilityLabel("Base URL")
        }
        providerInputRow(label: "API Key") {
            SingleLineTextField(text: editableAPIKeyBinding(), isSecure: true)
                .accessibilityLabel("API Key")
        }
    }

    private func providerInputRow<Field: View>(
        label: LocalizedStringKey,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .center, spacing: ProviderFieldLayout.rowSpacing) {
            Text(label)
                .font(.body)
                .frame(width: ProviderFieldLayout.labelWidth, alignment: .leading)
                .lineLimit(1)
            field()
                .frame(height: ProviderFieldLayout.fieldHeight)
                .frame(maxWidth: .infinity)
        }
    }

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

    /// HOM-126：「标签分类」配置区。
    ///
    /// 设计：
    /// - 「标签分类」是自动化页的一等配置区，标题放在面板外并始终展示配置内容，
    ///   避免用户还要额外展开才能发现关键开关。
    /// - 总开关 OFF 时下面所有子项 `.disabled(true)` + `.opacity(0.5)`，符合 HOM-126
    ///   验收"总开关关闭时所有子项 disabled"。
    /// - 触发时机用三个独立 Toggle（启动 / 同步 / 定时），UI 简单直接；不用 Picker
    ///   是因为三者可同时开（"启动后跑一次 + 同步后增量 + 每天定时"）。
    /// - 处理范围用 Stepper（5...500，步进 5）+ 排序 Picker。
    /// - 阈值用 Slider（与 BatchAIOptionsSheet 的阈值滑条视觉一致），范围 0.5...1.0
    ///   步进 0.05；显示百分比。
    /// - 运行状态用只读 LabeledContent + 「立刻手动触发一次」按钮。
    private var autoTidySection: some View {
        Section {
            autoTidyContent
        } header: {
            SettingsSectionHeader(
                "settings.autoTidy.section",
                systemImage: "wand.and.stars"
            )
        }
    }

    /// 仓库分组的独立全局配置。
    ///
    /// 标签是 Starcat 本地数据，而仓库分组会写入 GitHub Lists。两者的授权边界和
    /// 置信度不能放在同一个配置组里，否则调整标签策略时可能意外改变远端写入行为。
    /// 自动化页需要并列展示两组完整配置，因此标题位于面板外，内容不再折叠。
    private var githubListGroupingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                // 与「标签分类」总开关同款：标题与备注分行，避免 Toggle thumb 被挤出裁切。
                // 备注只说后台整理未分组仓库；启动 / 同步触发已拆到下方独立开关，不能再写死。
                Toggle("settings.githubListGrouping.enabled.title", isOn: githubListGroupingBinding(\.enabled))
                    .toggleStyle(.switch)
                    .padding(.vertical, 8)

                Text("settings.githubListGrouping.enabled.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)

                Group {
                    githubListGroupingTriggerGroup
                    githubListGroupingRangeGroup

                    Divider()
                    autoTidySectionHeader("settings.autoTidy.actions.label")
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
                }
                .disabled(!settings.githubStarListAutoGroupingSettings.enabled)
                .opacity(settings.githubStarListAutoGroupingSettings.enabled ? 1.0 : 0.5)
            }
            .padding(.top, 4)
        } header: {
            SettingsSectionHeader(
                "settings.githubListGrouping.section",
                systemImage: "folder.badge.gearshape"
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
        autoTidySectionHeader("settings.autoTidy.triggers.label")

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
        autoTidySectionHeader("settings.autoTidy.range.label")

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
            Toggle("settings.autoTidy.enabled.title", isOn: autoTidyBinding(\.enabled))
                .toggleStyle(.switch)
                .padding(.vertical, 8)

            Text("settings.autoTidy.enabled.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            Group {
                triggerGroup
                rangeGroup
                actionsGroup
                statusGroup
            }
            .disabled(!settings.autoTidySettings.enabled)
            .opacity(settings.autoTidySettings.enabled ? 1.0 : 0.5)
        }
        .padding(.top, 4)
    }

    /// 子分组标题：横线上方的次要标签，上下留白与配置行一致。
    private func autoTidySectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 8)
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
        autoTidySectionHeader("settings.autoTidy.triggers.label")

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
        autoTidySectionHeader("settings.autoTidy.range.label")

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

    /// 执行操作：摘要 / 标签 + 置信度阈值。
    @ViewBuilder
    private var actionsGroup: some View {
        Divider()
        autoTidySectionHeader("settings.autoTidy.actions.label")

        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.actions.generateTags",
                description: "settings.autoTidy.actions.generateTags.description",
                isOn: autoTidyBinding(\.generateTags)
            )
        }
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
        .disabled(!settings.autoTidySettings.generateTags)
        .opacity(settings.autoTidySettings.generateTags ? 1.0 : 0.5)
        Divider()
        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.actions.generateSummary",
                description: "settings.autoTidy.actions.generateSummary.description",
                isOn: autoTidyBinding(\.generateSummary)
            )
        }
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
        .disabled(!settings.autoTidySettings.generateTags)
        .opacity(settings.autoTidySettings.generateTags ? 1.0 : 0.5)
    }

    /// 运行状态只读 + 手动触发按钮。
    /// 即使总开关关着，「立刻手动触发一次」也保持可点（用户可能想"现在跑一次试试效果再决定要不要开总开关"）。
    /// 但 disabled group 把这里也锁住了——为了避免特殊化处理破坏 disabled 整体语义，
    /// 我们干脆把状态区也放在 disabled 范围内；用户必须先开总开关才能手动触发。
    ///
    /// HOM-126 follow-up (dong4j 反馈 2026-06-07)：
    /// 整个状态卡片改右对齐——「运行状态」label、「上次自动跑 xxx」icon+text、
    /// 「立刻手动触发一次」按钮 + 运行进度文字，全部贴右侧。实现方式：在每行的
    /// HStack 开头放 `Spacer()`，把元素挤到右端；不再用 `.frame(maxWidth: .infinity,
    /// alignment: .leading)`。这样跟 dong4j 截图里 macOS Settings 标准右侧操作列
    /// 的视觉一致。
    @ViewBuilder
    private var statusGroup: some View {
        Divider()
        HStack {
            Spacer()
            Text("settings.autoTidy.status.label")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)

        // 上次运行时间 + 计数（贴右对齐）
        HStack(spacing: 6) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text(lastRunSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)

        Divider()

        // 手动触发按钮 + 当前是否在跑的轻量提示（按钮贴右对齐）
        HStack(spacing: 8) {
            Spacer()
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
                Label("settings.autoTidy.triggerNow", systemImage: "play.fill")
            }
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
        "\(Int((settings.autoTidySettings.confidenceThreshold * 100).rounded()))%"
    }

    /// 仓库分组拥有独立阈值，不能与标签自动应用共用同一显示值。
    private var githubListGroupingThresholdPercentString: String {
        "\(Int((settings.githubStarListAutoGroupingSettings.confidenceThreshold * 100).rounded()))%"
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

    /// `maxPerRun` 的独立 binding：Stepper 已经限定 5...500，但 binding 仍 clamp 一道
    /// 防御性兜底（避免外部按钮 / 快捷键 / 程序化路径写入越界值）。
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

    // MARK: - Prompt

    /// HOM-68 follow-up v3 (dong4j 反馈 2026-06-05 22:40)：
    /// - 任务 picker + "恢复默认" 之前同行抢宽度，picker 被挤；改成 picker
    ///   `.labelsHidden().frame(maxWidth: .infinity)` 优先吃满宽度，按钮固定
    ///   尺寸跟在右边；
    /// - 两个标题用 `.frame(maxWidth: .infinity, alignment: .leading)`
    ///   显式左对齐，避免 Form grouped 样式把它居中显示；
    /// - 两个 TextEditor 固定高度：System 通常更长，给 180；User 给一半高度 80。
    ///   TextEditor 在 macOS 上内置垂直滚动，超出高度自动出现滚动条，不再让长
    ///   prompt 撑大整个设置面板。
    private var promptSection: some View {
        // Prompt 有完整默认值但仍属于本一级页面；常驻展示并保留原分隔节奏。
        Section {
            // 与模型配置同款：等宽铺满剩余宽度；重置按钮固定在右侧。
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    EqualWidthSegmentedControl(
                        items: AIModelTask.aiSettingsPageTasks,
                        selection: $promptTask,
                        title: { LocalizedStringKey($0.displayNameKey) }
                    )
                    .accessibilityLabel("settings.ai.prompt.task.pickerLabel")

                    // HOM-126 follow-up (dong4j 反馈 2026-06-07)：「恢复默认」按钮去掉文字只保留 icon
                    // （扫一眼就懂 = 旋转箭头），节省横向空间让左侧 segmented picker 不被挤；语义留在 tooltip。
                    ResetIconButton(help: Text("settings.ai.prompt.restoreHelpFormat \(promptTask.displayName)")) {
                        restoreDefaultPrompt(promptTask)
                    }
                }
                .padding(.vertical, 10)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.ai.prompt.system")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextEditor(text: promptSystemBinding(promptTask))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 180)
                        .disabled(!promptTask.supportsSystemPrompt)
                        .opacity(promptTask.supportsSystemPrompt ? 1.0 : 0.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                    if !promptTask.supportsSystemPrompt {
                        Text("settings.ai.prompt.system.embeddingUnavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.ai.prompt.user")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextEditor(text: promptUserBinding(promptTask))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .disabled(!promptTask.supportsUserPromptTemplate)
                        .opacity(promptTask.supportsUserPromptTemplate ? 1.0 : 0.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                    if !promptTask.supportsUserPromptTemplate {
                        Text("settings.ai.prompt.user.chatUnavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)

                Divider()

                // 对齐设置页独立操作按钮右对齐规范：长文案收进 popover，底部只留入口。
                HStack {
                    Spacer(minLength: 0)
                    promptPlaceholderHelpButton
                }
                .padding(.vertical, 10)
            }
            .onChange(of: promptTask) { _, _ in
                isPromptPlaceholderPopoverPresented = false
            }
        } header: {
            SettingsSectionHeader(
                "settings.ai.prompt.title",
                systemImage: "text.quote"
            )
        }
    }

    /// 底部入口：点开看 token + 含义，避免设置页底部一长段 bullet。
    private var promptPlaceholderHelpButton: some View {
        Button {
            isPromptPlaceholderPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(.caption2.weight(.semibold))
                Text("settings.ai.prompt.placeholders.open")
                    .font(.caption.weight(.medium))
                Image(systemName: "info.circle")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("settings.ai.prompt.placeholders.openHelp")
        .popover(isPresented: $isPromptPlaceholderPopoverPresented, arrowEdge: .top) {
            AIPromptPlaceholderPopover(catalog: AIPromptPlaceholderCatalog.catalog(
                for: promptTask
            ))
                .appLocaleEnvironment()
        }
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
                systemImage: "brain.head.profile"
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
                systemImage: "shippingbox.fill"
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

    private func beginDraft(provider: AIServiceProvider) {
        AppLog.ai.debug("[AISettings] beginDraft(provider:) called provider=\(provider.rawValue, privacy: .public) prevDraftID=\(self.draftProfile?.id ?? "nil", privacy: .public)")
        var profile = AIProviderProfile(provider: provider)
        // 草稿默认不启用，防止它在测试通过前进入任务模型选择或真实 AI 调用链。
        profile.isEnabled = false
        draftProfile = profile
        draftAPIKey = ""
        keyError = nil
    }

    private func beginDraft(from profile: AIProviderProfile) {
        AppLog.ai.debug("[AISettings] beginDraft(from:) called fromID=\(profile.id, privacy: .public) prevDraftID=\(self.draftProfile?.id ?? "nil", privacy: .public)")
        var copy = profile
        // 编辑已验证配置时也先变成草稿，同 ID 测试通过后覆盖原配置。这样用户改 Base URL
        // 或 API Key 时，不会让未验证的新值直接进入真实 AI 调用链。
        copy.isEnabled = false
        copy.lastTestStatus = .notTested
        draftProfile = copy
        draftAPIKey = apiKeys[profile.id, default: ""]
        keyError = nil
    }

    /// 放弃未完成的服务商草稿。草稿从未写入 `aiProviderProfiles`，所以只清内存态。
    /// 编辑已有服务商时，落盘配置仍在原 ID 上，丢掉草稿即恢复已保存值。
    private func discardDraft() {
        guard draftProfile != nil else { return }
        AppLog.ai.debug("[AISettings] discardDraft() draftID=\(self.draftProfile?.id ?? "nil", privacy: .public)")
        draftProfile = nil
        draftAPIKey = ""
        keyError = nil
    }

    /// 点 `+` 生成的新草稿 ID 不在已保存列表里；从已有 profile 提升的草稿沿用原 ID。
    private var isAddingNewProviderDraft: Bool {
        guard let draftID = draftProfile?.id else { return false }
        return !settings.aiProviderProfiles.contains { $0.id == draftID }
    }

    // `deleteSelectedProfile()` 已被 `deleteProfile(id:)` + `confirmationDialog`
    // 二次确认链路取代（HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12）。原函数
    // 隐式依赖 `selectedProfileID`，confirm dialog 期间用户可能切换 selection
    // 导致语义偏差，新函数收紧到显式 ID 删除。

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
        keyError = nil
        defer { isTestingProfileID = nil }

        let testingKey = apiKey(for: profile)
        do {
            let client = try AIClientFactory.make(configuration: AIClientConfiguration(
                providerID: profile.id,
                provider: profile.provider,
                apiKey: testingKey,
                baseURL: profile.baseURL,
                chatModel: profile.models.first(where: { $0.capability == .chat })?.name ?? profile.provider.defaultChatModel,
                embeddingModel: profile.models.first(where: { $0.capability == .embedding })?.name ?? profile.provider.defaultEmbeddingModel,
                timeoutInterval: 60
            ))
            let models = try await client.listModels()

            var verified = profile
            if let anthropic = client as? AnthropicClient {
                verified.baseURL = anthropic.probedBaseURL
            }
            // 去重 / 大目录不全开 / 容量上限：避免 OpenRouter 类目录在勾选时卡死主线程。
            verified.mergeDiscoveredModels(
                models,
                referencedModelNames: referencedModelNames(for: profile.id)
            )
            verified.isEnabled = true
            verified.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
            verified.lastTestStatus = .success(modelCount: verified.models.count)

            try persistAPIKey(testingKey, forProvider: profile.id, allowsEmpty: profile.provider.allowsEmptyAPIKey)

            if isActiveProfileDraft(profile.id) {
                var profiles = settings.aiProviderProfiles
                profiles.removeAll { $0.id == profile.id }
                profiles.append(verified)
                settings.aiProviderProfiles = profiles
                setSelectedProfileID(profile.id)
                // HOM-AIPROVIDERS-HIDE-PROVIDER-2026-06-12：包 withAnimation 让
                // Provider 行随草稿晋升收起，与点 + 时的滑入动画对称。
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    draftProfile = nil
                    draftAPIKey = ""
                }
            } else {
                updateProfile(profile.id) { current in
                    current = verified
                }
            }
            apiKeys[profile.id] = testingKey
            repairTasksAfterProfileChange()
        } catch {
            if isActiveProfileDraft(profile.id) {
                draftProfile?.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
                draftProfile?.lastTestStatus = .failed(error.localizedDescription)
            } else {
                updateProfile(profile.id) { current in
                    current.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
                    current.lastTestStatus = .failed(error.localizedDescription)
                }
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

    private func canTest(_ profile: AIProviderProfile) -> Bool {
        let hasBaseURL = !profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKey = !apiKey(for: profile).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasBaseURL && (profile.provider.allowsEmptyAPIKey || hasKey)
    }

    private func apiKey(for profile: AIProviderProfile) -> String {
        if isActiveProfileDraft(profile.id) {
            return draftAPIKey
        }
        return apiKeys[profile.id, default: ""]
    }

    private func isActiveProfileDraft(_ profileID: String) -> Bool {
        draftProfile?.id == profileID
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
                // macOS Picker 在 Form 刷新时可能把当前 selection 原样写回一次。
                // 新增草稿时第一行仍显示原已验证配置（如 DeepSeek），如果重复写回也清空
                // draftProfile，就会出现“输入任意字符后草稿 provider 跳回 DeepSeek”。
                // 只有用户真正切到另一个已验证配置时，才丢弃草稿。
                //
                // HOM-AIPROVIDERS-NIL-WRITEBACK-2026-06-06 (dong4j 反馈"+号后输入
                // 任意内容、Provider 立马跳到第一个已配置好的服务商"):
                // 13:18 的修复处理了"同值写回"(`newSelection == selectedProfileID`),
                // 但 macOS SwiftUI Picker 在某些刷新时机会把 selection 写回 **nil**——
                // 典型场景:用户点 + 后 draftProfile 一直是非 verified(`isEnabled=false`),
                // Form 内每次输入触发 body 重算时 NSPopUpButton 的内部 selectedIndex 与
                // 我们 binding 短暂不一致,SwiftUI 当作"找不到匹配 tag"主动写 nil 回来。
                // `nil != selectedProfileID(=A.id)` 让旧 guard 失守,setSelectedProfileID(nil)
                // 把持久化清空 + 把 draftProfile 也一并清掉,导致 activeProfile 回退到
                // verifiedProfiles.first(DeepSeek),Picker 2 跟着跳。
                //
                // 防御:Picker 1 的所有 tag 都是非 nil 的 verified profile ID,经过它的
                // `newSelection == nil` 100% 不是用户主动操作(用户没法选 nil tag),而是
                // SwiftUI 内部 sync 副作用。直接忽略,不让它清掉 draft。
                // 真正需要把 selectedProfileID 置 nil 的路径(deleteSelectedProfile 后
                // 没有 verified profile)走 setSelectedProfileID(nil) 直接调用,不经过此
                // binding,所以这个 guard 不会误伤合法的 nil 写入。
                AppLog.ai.debug("[AISettings] selectedProfileBinding.set newSelection=\(newSelection ?? "nil", privacy: .public) currentSelectedProfileID=\(self.selectedProfileID ?? "nil", privacy: .public) draftID=\(self.draftProfile?.id ?? "nil", privacy: .public)")
                guard let newSelection else {
                    AppLog.ai.debug("[AISettings] selectedProfileBinding.set: nil write blocked")
                    return
                }
                guard newSelection != selectedProfileID else {
                    AppLog.ai.debug("[AISettings] selectedProfileBinding.set: same-value write blocked")
                    return
                }
                AppLog.ai.debug("[AISettings] selectedProfileBinding.set: APPLYING — clearing draft")
                setSelectedProfileID(newSelection)
                draftProfile = nil
                draftAPIKey = ""
                keyError = nil
            }
        )
    }

    private var supportedProviderBinding: Binding<AIServiceProvider> {
        Binding(
            get: { activeProfile?.provider ?? .openAICompatible },
            set: { provider in
                if draftProfile == nil || draftProfile?.provider != provider {
                    beginDraft(provider: provider)
                }
            }
        )
    }

    // HOM-AIPROVIDERS-COORDINATOR-STALE-BINDING-2026-06-06
    // (dong4j 反馈"+号后输入框打字会跳回 verified profile" — log 抓到关键证据:
    //  beginDraft(from:) 被错误调用 fromID=verifiedA prevDraftID=newDraft).
    //
    // 根因:`SingleLineTextField` 是 NSViewRepresentable,Coordinator 在
    // makeCoordinator() 时持有当时的 binding。binding closure 之前 capture 了
    // **当时**的 `profileID`(verified A 的 id)。SwiftUI re-render 创建新 binding
    // (新的 profileID = draft.id),但 NSViewRepresentable 不会重建 Coordinator,
    // 它继续用最初的 binding。用户在 NSTextField 打字时,Coordinator 调旧 setter,
    // 闭包内的 profileID 仍是旧 verified A 的 id,走 isActiveProfileDraft FALSE 分支,
    // → beginDraft(from: A) → draft 被替换成 A 的 copy → UI 跳回 verified profile。
    //
    // 修复:binding closure **不依赖 captured profileID**,而是通过 `draftProfile` /
    // `selectedProfileID` 这两个 @State / @AppStorage 直接动态查最新状态。
    // SwiftUI @State 通过 wrapper 间接引用 SwiftUI 内部 storage,即使 self 是旧的
    // struct value,property wrapper 内部访问到的还是 latest storage,从而绕过
    // "Coordinator 持有 stale binding" 这个 NSViewRepresentable 的固有问题。
    //
    // 副作用:这两个 binding 的语义从"按 profileID 编辑"变成"按当前 active profile
    // 编辑"。view body 不再传 profileID。

    private func editableAPIKeyBinding() -> Binding<String> {
        Binding(
            get: {
                if draftProfile != nil {
                    return draftAPIKey
                }
                if let id = selectedProfileID {
                    return apiKeys[id, default: ""]
                }
                return ""
            },
            set: { newValue in
                if draftProfile != nil {
                    draftAPIKey = newValue
                } else if let id = selectedProfileID, let current = profile(id) {
                    AppLog.ai.debug("[AISettings] editableAPIKeyBinding.set: promoting verified \(id, privacy: .public) to draft")
                    beginDraft(from: current)
                    draftAPIKey = newValue
                }
            }
        )
    }

    private func editableProfileTextBinding(
        keyPath: WritableKeyPath<AIProviderProfile, String>
    ) -> Binding<String> {
        Binding(
            get: {
                if let draft = draftProfile {
                    return draft[keyPath: keyPath]
                }
                if let id = selectedProfileID, let p = profile(id) {
                    return p[keyPath: keyPath]
                }
                return ""
            },
            set: { newValue in
                if draftProfile != nil {
                    draftProfile?[keyPath: keyPath] = newValue
                    draftProfile?.lastTestStatus = .notTested
                } else if let id = selectedProfileID, let current = profile(id) {
                    AppLog.ai.debug("[AISettings] editableProfileTextBinding.set: promoting verified \(id, privacy: .public) to draft")
                    beginDraft(from: current)
                    draftProfile?[keyPath: keyPath] = newValue
                }
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

    private func taskProviderBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).providerID },
            set: { providerID in
                updateTask(task) { config in
                    config.providerID = providerID
                    if let first = enabledModels(providerID: providerID, capability: task.requiredCapability).first {
                        config.modelID = first.name
                        config.customModelName = first.name
                        config.useCustomModel = false
                    }
                }
            }
        )
    }

    private func taskModelBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).modelID },
            set: { modelName in
                settings.selectLocalAIModel(named: modelName, providerID: taskConfig(task).providerID)
                updateTask(task) { config in
                    config.modelID = modelName
                    // 选列表模型时关掉自定义开关，但保留 customModelName，
                    // 避免用户关掉/重开开关后发现上次手填内容被冲掉。
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
        draftProfile ?? selectedProfile
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

    // `groupedEnabledModels(for:)` 已删除：HOM-68 follow-up v3 把"任务 → 模型"下拉
    // 收紧到只列当前 provider 的模型（见 `taskModelRow`），消除跨 provider 同名模型
    // 同时选中的视觉 bug。
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

    private func statusTint(_ status: AIProviderTestStatus) -> Color {
        switch status {
        case .notTested:
            return .secondary
        case .success:
            return .green
        case .failed:
            return .red
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
                Task { @MainActor [weak self] in
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
