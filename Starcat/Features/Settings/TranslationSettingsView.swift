//
//  TranslationSettingsView.swift
//  Starcat
//
//  「翻译服务」设置页：默认引擎 + Apple / Google 翻译凭据 + AI 翻译配置。
//
//  2026-09-11 起翻译相关的 AI 配置从「AI 服务」迁入本页（dong4j 拍板）：
//  - AI 的服务商 / 模型目录仍归「AI 服务」页维护，本页只负责「用谁译」；
//  - 默认引擎选中 AI 翻译后，在本页从已配置服务商中挑 Chat 模型，并维护
//    分段 / 全文两套 Prompt；模型参数跟随模型本身（AI 服务页模型列表），
//    不在本页出现；
//  - AI 区块固定放页面最后：后续新增翻译引擎时按引擎追加 Section。
//

import SwiftUI

struct TranslationSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var availableEngines: [ReadmeTranslationEngine] = []
    @State private var systemLanguageCatalog = SystemTranslationLanguageCatalog()
    @State private var isSystemLanguageManagerPresented = false
    @State private var googleAPIKey = ""
    @State private var hasStoredGoogleAPIKey = false
    @State private var isGoogleAPIKeyVisible = false
    /// 「测试并保存」进行中：测试期间禁用按钮并显示进度。
    @State private var isTestingGoogleKey = false
    /// Key 测试 / 保存失败原因，展示在状态行下方。
    @State private var googleKeyError: String?

    /// AI 翻译 Prompt 的二级 Tab。只切换 Prompt，不复制 Provider / Model 配置。
    @State private var promptMode: ReadmeTranslationMode = .segmented
    /// 「可用占位符」popover；切换模式时关闭，避免旧模式说明残留。
    @State private var isPromptPlaceholderPopoverPresented = false

    var body: some View {
        Form {
            engineSection
            // dong4j 2026-09-11 确认：引擎专属配置只在该引擎被选中时展示，
            // 后续新增翻译引擎也按此规则追加 Section。
            if settings.readmeTranslationEngine == .system {
                systemTranslationSection
            }
            if settings.readmeTranslationEngine == .google {
                googleSection
            }
            if settings.readmeTranslationEngine == .ai {
                aiTranslationSection
            }
        }
        .formStyle(.grouped)
        .task(id: settings.effectiveReadmeTranslationLanguage) {
            await refreshEngines()
        }
        .task {
            loadGoogleAPIKey()
        }
        .sheet(isPresented: $isSystemLanguageManagerPresented) {
            SystemTranslationLanguageManagerSheet(
                targetLanguage: settings.effectiveReadmeTranslationLanguage,
                catalog: systemLanguageCatalog,
                openSystemSettings: openSystemLanguageSettings
            )
            .appLocaleEnvironment()
        }
    }

    // MARK: - 引擎选择

    private var engineSection: some View {
        Section {
            if availableEngines.isEmpty {
                Text("settings.translation.engine.empty")
                    .foregroundStyle(.secondary)
            } else {
                Picker(selection: Binding(
                    get: { settings.readmeTranslationEngine },
                    set: { settings.readmeTranslationEngine = $0 }
                )) {
                    ForEach(availableEngines) { engine in
                        Text(LocalizedStringKey(engine.displayNameKey)).tag(engine)
                    }
                } label: {
                    Text("settings.translation.engine.default")
                }
            }
        } header: {
            Text("settings.translation.section.engine")
        } footer: {
            Text("settings.translation.section.engine.footer")
        }
    }

    // MARK: - 系统翻译

    /// 仅默认引擎 = 系统翻译时显示。这里展示语言组合的实时摘要；完整列表和下载
    /// 交给独立 Sheet，避免把二十余种语言直接铺进主设置页。
    private var systemTranslationSection: some View {
        let target = settings.effectiveReadmeTranslationLanguage
        return Section {
            LabeledContent("settings.translation.system.targetLanguage") {
                Text(verbatim: target.displayName)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.translation.system.languages")
                        .foregroundStyle(.primary)
                    Text(verbatim: systemLanguageReadinessText(for: target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("settings.translation.system.manage") {
                    isSystemLanguageManagerPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            HStack {
                Spacer(minLength: 0)
                Button(action: openSystemLanguageSettings) {
                    Label(
                        "settings.translation.system.openSettings",
                        systemImage: "gearshape"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        } header: {
            SettingsSectionHeader(
                "settings.translation.section.system",
                systemImage: "character.bubble"
            )
        } footer: {
            Text("settings.translation.section.system.footer")
        }
        .task(id: target.rawValue) {
            await systemLanguageCatalog.refresh(target: target)
        }
    }

    private func systemLanguageReadinessText(
        for target: ReadmeTranslationLanguage
    ) -> String {
        guard systemLanguageCatalog.isLoaded(for: target) else {
            return String.l10n("settings.translation.system.readiness.loading")
        }
        return String(
            format: String.l10n("settings.translation.system.readiness.format"),
            systemLanguageCatalog.readyCount,
            systemLanguageCatalog.availablePairCount
        )
    }

    /// Apple 没有公开直接弹出「翻译语言」二级窗口的稳定 API；打开官方支持的
    /// 「语言与地区」面板，由用户进入翻译语言完成删除或全局管理。
    private func openSystemLanguageSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Localization-Settings.extension"
        ) else { return }
        openURL(url)
    }

    // MARK: - Google 翻译

    /// 仅默认引擎 = Google 翻译时显示（dong4j 2026-09-11 确认）。
    private var googleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.translation.google.description")
                    // 对齐 DESIGN.md caption 规格：辅助说明 12px / 400，不再用默认 body 撑大行高。
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if isGoogleAPIKeyVisible {
                        TextField(
                            "settings.translation.google.apiKey.field",
                            text: $googleAPIKey
                        )
                        .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(
                            "settings.translation.google.apiKey.field",
                            text: $googleAPIKey
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isGoogleAPIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isGoogleAPIKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(Text(isGoogleAPIKeyVisible
                        ? "settings.translation.google.apiKey.hide"
                        : "settings.translation.google.apiKey.show"))
                }

                HStack {
                    Text(googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "settings.translation.google.publicMode"
                        : "settings.translation.google.cloudMode")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await testAndSaveGoogleKey() }
                    } label: {
                        // 与 AI 服务页「测试并获取模型」同款：测试期间按钮内嵌进度。
                        if isTestingGoogleKey {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("settings.translation.google.apiKey.testAndSave")
                            }
                        } else {
                            Text("settings.translation.google.apiKey.testAndSave")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isTestingGoogleKey
                        || (googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !hasStoredGoogleAPIKey))
                }

                if let googleKeyError {
                    Text(googleKeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("settings.translation.google.openConsole") {
                        guard let url = URL(string: "https://console.cloud.google.com/apis/credentials") else { return }
                        openURL(url)
                    }
                }
            }
        } header: {
            Text("settings.translation.section.google")
        } footer: {
            Text("settings.translation.section.google.rateLimitFooter")
        }
    }

    // MARK: - AI 翻译

    /// 仅默认引擎 = AI 翻译时显示（dong4j 2026-09-11 确认）。引擎可用性沿用
    /// 「不可用不出现」规则：没有已配置服务商时引擎列表里没有 AI，本区块也不会出现，
    /// 因此无需额外的「未配置」空态。
    private var aiTranslationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                // 与 AI 服务页「模型配置」行同款交互：左 label + 右双下拉。
                trailingRow(label: "settings.ai.task.providerLabel") {
                    Picker("settings.ai.task.providerLabel", selection: providerBinding) {
                        ForEach(verifiedProfiles) { profile in
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

                trailingRow(label: "settings.ai.task.modelLabel") {
                    Picker("settings.ai.task.modelLabel", selection: modelBinding) {
                        if enabledModels.isEmpty {
                            Text("settings.translation.ai.model.empty")
                                .tag("")
                        } else {
                            ForEach(enabledModels) { model in
                                Text(AnthropicModelCatalog.displayName(forAPIID: model.name)).tag(model.name)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Divider()

                // 提示词行：二级 Tab 只切 Prompt；↺ 重置当前选中模式。
                HStack(spacing: 12) {
                    Text("settings.translation.ai.prompt")
                        .foregroundStyle(.primary)
                    EqualWidthSegmentedControl(
                        items: ReadmeTranslationMode.allCases,
                        selection: $promptMode,
                        title: { LocalizedStringKey($0.displayNameKey) }
                    )
                    .accessibilityLabel("settings.ai.prompt.translation.mode.pickerLabel")
                    ResetIconButton(
                        help: Text("settings.translation.ai.prompt.restoreHelp \(String.l10n(promptMode.displayNameKey))")
                    ) {
                        restoreDefaultPrompt()
                    }
                }
                .padding(.vertical, 10)

                Divider()

                promptEditor(
                    titleKey: "settings.ai.prompt.system",
                    binding: promptSystemBinding,
                    height: 180
                )
                .padding(.vertical, 10)

                Divider()

                promptEditor(
                    titleKey: "settings.ai.prompt.user",
                    binding: promptUserBinding,
                    height: 80
                )
                .padding(.vertical, 10)

                Divider()

                // 对齐设置页独立操作按钮右对齐规范：长文案收进 popover，底部只留入口。
                HStack {
                    Spacer(minLength: 0)
                    placeholderHelpButton
                }
                .padding(.vertical, 10)
            }
            .onChange(of: promptMode) { _, _ in
                isPromptPlaceholderPopoverPresented = false
            }
        } header: {
            Text("settings.translation.ai.section")
        } footer: {
            Text("settings.translation.ai.footer")
        }
    }

    /// 设置行：左侧 label、右侧控件（一左一右）。
    private func trailingRow<Content: View>(
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

    /// System / User Prompt 编辑器：等宽字体 + 固定高度（超出内部滚动），描边提示可编辑区。
    private func promptEditor(
        titleKey: LocalizedStringKey,
        binding: Binding<String>,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleKey)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: binding)
                .font(.system(.caption, design: .monospaced))
                .frame(height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
    }

    /// 底部入口：点开看 token + 含义，与 AI 服务页 Prompt 区同一套组件。
    private var placeholderHelpButton: some View {
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
                for: .translation,
                translationMode: promptMode
            ))
                .appLocaleEnvironment()
        }
    }

    // MARK: - AI 翻译数据源

    /// 与 AI 服务页任务下拉同口径：仅「已启用 + 测试通过」的服务商可入列。
    private var verifiedProfiles: [AIProviderProfile] {
        settings.aiProviderProfiles.filter(\.isVerifiedConfiguration)
    }

    /// 当前翻译任务服务商下可入选的模型。
    private var enabledModels: [AIModelDescriptor] {
        guard let profile = settings.aiProviderProfiles.first(
            where: { $0.id == settings.aiTranslationTask.providerID }
        ), profile.isVerifiedConfiguration else { return [] }
        return enabledModels(in: profile)
    }

    /// 翻译模型口径（dong4j 2026-09-11 确认）：Chat + Unknown 且已启用。
    /// 与 AI 服务页 `enabledModels(providerID:capability:)` 的 chat 过滤保持一致。
    private func enabledModels(in profile: AIProviderProfile) -> [AIModelDescriptor] {
        profile.models.filter {
            $0.isEnabled && ($0.capability == .chat || $0.capability == .unknown)
        }
    }

    // MARK: - AI 翻译 Bindings

    /// 切服务商时自动选该服务商第一个可用模型，并关闭自定义模型开关。
    private var providerBinding: Binding<String> {
        Binding(
            get: { settings.aiTranslationTask.providerID },
            set: { providerID in
                var config = settings.aiTranslationTask
                config.providerID = providerID
                if let profile = settings.aiProviderProfiles.first(where: { $0.id == providerID }),
                   profile.isVerifiedConfiguration,
                   let first = enabledModels(in: profile).first {
                    config.modelID = first.name
                    config.useCustomModel = false
                }
                settings.aiTranslationTask = config
            }
        )
    }

    /// 选目录模型时关闭自定义开关；`customModelName` 保留不清，
    /// 与 AI 服务页任务模型下拉语义一致。
    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.resolvedAITask(settings.aiTranslationTask).modelID },
            set: { modelName in
                var config = settings.aiTranslationTask
                settings.selectLocalAIModel(named: modelName, providerID: config.providerID)
                config.modelID = modelName
                config.useCustomModel = false
                settings.aiTranslationTask = config
            }
        )
    }

    /// 分段模式读写 `aiTranslationTask.prompt`；全文模式读写独立的 `aiFullTranslationPrompt`。
    private var promptSystemBinding: Binding<String> {
        if promptMode == .full {
            return Binding(
                get: { settings.aiFullTranslationPrompt.systemPrompt },
                set: { value in
                    var prompt = settings.aiFullTranslationPrompt
                    prompt.systemPrompt = value
                    settings.aiFullTranslationPrompt = prompt
                }
            )
        }
        return Binding(
            get: { settings.aiTranslationTask.prompt.systemPrompt },
            set: { value in
                var config = settings.aiTranslationTask
                config.prompt.systemPrompt = value
                settings.aiTranslationTask = config
            }
        )
    }

    private var promptUserBinding: Binding<String> {
        if promptMode == .full {
            return Binding(
                get: { settings.aiFullTranslationPrompt.userPromptTemplate },
                set: { value in
                    var prompt = settings.aiFullTranslationPrompt
                    prompt.userPromptTemplate = value
                    settings.aiFullTranslationPrompt = prompt
                }
            )
        }
        return Binding(
            get: { settings.aiTranslationTask.prompt.userPromptTemplate },
            set: { value in
                var config = settings.aiTranslationTask
                config.prompt.userPromptTemplate = value
                settings.aiTranslationTask = config
            }
        )
    }

    /// 与 AI 服务页同语义：分段重置任务内 Prompt，全文重置独立存储的全文 Prompt。
    private func restoreDefaultPrompt() {
        if promptMode == .full {
            settings.aiFullTranslationPrompt = AIDefaultPrompts.fullTranslation
            return
        }
        var config = settings.aiTranslationTask
        config.prompt = AIDefaultPrompts.translation
        settings.aiTranslationTask = config
    }

    // MARK: - 引擎可用性

    @MainActor
    private func refreshEngines() async {
        let available = await ReadmeTranslationEngineAvailability.availableEngines(
            targetLanguage: settings.effectiveReadmeTranslationLanguage,
            settings: settings,
            keychain: KeychainManager.shared
        )
        availableEngines = available
        let resolved = ReadmeTranslationEngineAvailability.resolvedDefault(
            current: settings.readmeTranslationEngine,
            available: available
        )
        if resolved != settings.readmeTranslationEngine, !available.isEmpty {
            settings.readmeTranslationEngine = resolved
        }
    }

    /// 「测试并保存」（dong4j 2026-09-11 确认）：先用候选 Key 实际调一次 Cloud
    /// Translation（与运行时同一条路径），成功才写入 Starcat 的加密凭据文件；
    /// 失败不落盘，已保存的旧 Key 保持不变。
    /// 字段为空且已有存量 Key 时视为「清除」，直接删除回到无 Key 公开通道（无需测试）。
    @MainActor
    private func testAndSaveGoogleKey() async {
        let trimmed = googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            deleteGoogleAPIKey()
            return
        }

        isTestingGoogleKey = true
        googleKeyError = nil
        defer { isTestingGoogleKey = false }

        // 用候选 Key 走一次真实 Cloud 请求；目标语取当前翻译目标语，让测试贴近真实使用。
        let client = GoogleTranslationClient(apiKey: trimmed)
        do {
            _ = try await client.translate(
                texts: ["hello"],
                targetLanguage: settings.effectiveReadmeTranslationLanguage
            )
        } catch {
            googleKeyError = error.localizedDescription
            return
        }

        do {
            try KeychainManager.shared.storeServiceAPIKey(
                trimmed,
                forService: GoogleTranslationClient.keychainServiceID
            )
            googleAPIKey = trimmed
            hasStoredGoogleAPIKey = true
        } catch {
            googleKeyError = error.localizedDescription
            AppLog.keychain.error(
                "Google Translation API key update failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func deleteGoogleAPIKey() {
        do {
            try KeychainManager.shared.deleteServiceAPIKey(
                forService: GoogleTranslationClient.keychainServiceID
            )
            googleAPIKey = ""
            hasStoredGoogleAPIKey = false
            googleKeyError = nil
        } catch {
            googleKeyError = error.localizedDescription
            AppLog.keychain.error(
                "Google Translation API key delete failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func loadGoogleAPIKey() {
        googleAPIKey = (try? KeychainManager.shared.loadServiceAPIKey(
            forService: GoogleTranslationClient.keychainServiceID
        )) ?? ""
        hasStoredGoogleAPIKey = !googleAPIKey.isEmpty
    }
}

#Preview {
    TranslationSettingsTab()
        .environment(AppSettings.shared)
}
