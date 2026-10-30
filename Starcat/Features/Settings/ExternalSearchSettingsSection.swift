//
//  ExternalSearchSettingsSection.swift
//  Starcat
//
//  设置 → AI → 搜索与上下文：联网搜索配置。
//
//  模块级说明：
//  - 本视图从原“集成”页拆出联网搜索开关、Provider 与凭据测试。
//  - Provider 元数据继续写入 AppSettings，API Key 继续走既有安全存储。
//  - 仅调整信息架构，不改变匿名模式、Pro 聚合能力或凭据验证语义。
//

import SwiftUI

/// 联网搜索设置 Section，可直接嵌入主设置的 grouped Form。
struct ExternalSearchSettingsSection: View {

    @Environment(AppSettings.self) private var settings

    @State private var externalSearchAPIKeys: [ExternalSearchProviderID: String] = [:]
    @State private var visibleExternalSearchAPIKeys: Set<ExternalSearchProviderID> = []
    @State private var expandedExternalSearchProviders: Set<ExternalSearchProviderID> = []
    @State private var expandedExternalSearchTechnicalDetails: Set<ExternalSearchProviderID> = []
    @State private var externalSearchAPIKeyTestStates: [ExternalSearchProviderID: APIKeyTestState] = [:]

    var body: some View {
        anySearchSection
            .task {
                loadExternalSearchAPIKeys()
            }
    }

    private var anySearchSection: some View {
        @Bindable var settings = settings
        return Group {
            Section {
                Toggle("settings.externalSearch.includeWebInAll", isOn: $settings.externalSearchIncludeInAll)
                Text("settings.externalSearch.includeWebInAll.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("settings.externalSearch.aiContext", isOn: $settings.externalContextEnabled)
                Text("settings.externalSearch.aiContext.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(isOn: aggregateExternalContextBinding) {
                    HStack(spacing: 6) {
                        Text("settings.externalSearch.aggregate")
                        if !settings.isProUser {
                            Text("Pro")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        }
                    }
                }
                .disabled(!settings.isProUser)

                Toggle("settings.externalSearch.allowPrivateContext", isOn: $settings.externalSearchAllowPrivateRepos)
                    .disabled(!settings.externalContextEnabled)

                Picker("settings.externalSearch.defaultProvider", selection: $settings.externalSearchDefaultProvider) {
                    ForEach(ExternalSearchProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Picker("settings.externalSearch.contextProvider", selection: $settings.externalContextProviderSelection) {
                    Text("settings.externalSearch.contextProvider.automatic").tag(ExternalContextProviderSelection.automatic)
                    ForEach(ExternalSearchProviderID.allCases) { provider in
                        Text(provider.displayName).tag(ExternalContextProviderSelection.provider(provider))
                    }
                }

                Text("settings.externalSearch.aggregate.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("settings.externalSearch.apiKey.testDescription")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                externalSearchProviderList
            } header: {
                SettingsSectionHeader(
                    "settings.navigation.item.externalSearch",
                    systemImage: "globe"
                )
            }
        }
    }

    /// Provider 直接作为 Section 的 Form 行输出，复用系统行高、分隔线和字号适配。
    /// 不能再套一层 VStack，否则 Form 只会把整个 Provider 列表识别为单行，内部只能
    /// 依赖固定高度和手动画 Divider，首尾也会叠加不一致的行内边距。
    @ViewBuilder
    private var externalSearchProviderList: some View {
        ForEach(ExternalSearchProviderID.allCases) { provider in
            externalSearchProviderHeader(provider)

            if expandedExternalSearchProviders.contains(provider) {
                Toggle(isOn: providerEnabledBinding(provider)) {
                    Text("settings.externalSearch.provider.enable")
                }
                .disabled(!canToggleProviderOn(provider))

                if provider.supportsAnonymous {
                    Toggle("settings.externalSearch.anonymous", isOn: providerAnonymousBinding(provider))
                        .disabled(!settings.externalSearchSettings(for: provider).isEnabled)
                }

                if provider == .firecrawl {
                    Toggle("settings.externalSearch.firecrawl.fullText", isOn: providerFetchFullTextBinding(provider))
                        .disabled(!settings.externalSearchSettings(for: provider).isEnabled)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("settings.externalSearch.apiKey")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Link(
                            "settings.externalSearch.apiKey.get",
                            destination: externalSearchAPIKeyURL(for: provider)
                        )
                        .font(.caption.weight(.medium))
                    }

                    HStack(spacing: 8) {
                        Group {
                            if visibleExternalSearchAPIKeys.contains(provider) {
                                TextField("", text: apiKeyBinding(provider), prompt: Text(String(format: String.l10n("settings.externalSearch.apiKey.placeholderFormat"), provider.displayName)))
                            } else {
                                SecureField("", text: apiKeyBinding(provider), prompt: Text(String(format: String.l10n("settings.externalSearch.apiKey.placeholderFormat"), provider.displayName)))
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(Text(String(format: String.l10n("settings.externalSearch.apiKey.accessibilityFormat"), provider.displayName)))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)

                        Button {
                            toggleAPIKeyVisibility(provider)
                        } label: {
                            Image(systemName: visibleExternalSearchAPIKeys.contains(provider) ? "eye.slash" : "eye")
                                .font(SettingsIconMetrics.standardGlyph)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(visibleExternalSearchAPIKeys.contains(provider) ? "settings.externalSearch.apiKey.hide" : "settings.externalSearch.apiKey.show")
                        .accessibilityLabel(Text(visibleExternalSearchAPIKeys.contains(provider) ? "settings.externalSearch.apiKey.hide" : "settings.externalSearch.apiKey.show"))
                    }
                }

                // 测试是独立操作，按设置页规范右对齐；结果与错误留在同行左侧，
                // 用户无需在 API Key 输入行和下方反馈之间来回寻找状态。
                HStack(alignment: .center, spacing: 8) {
                    externalSearchAPIKeyTestFeedback(provider)
                    // EmptyView 不参与布局，必须用独立 Spacer 保证无反馈时按钮仍右对齐。
                    Spacer(minLength: 8)

                    Button {
                        testExternalSearchAPIKey(provider)
                    } label: {
                        if externalSearchAPIKeyTestStates[provider] == .testing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("settings.externalSearch.apiKey.test")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .fixedSize()
                    .disabled(!canTestExternalSearchKey(provider))
                }
            }
        }
    }

    private func externalSearchProviderHeader(_ provider: ExternalSearchProviderID) -> some View {
        let isExpanded = expandedExternalSearchProviders.contains(provider)
        return Button {
            toggleExternalSearchProviderExpansion(provider)
        } label: {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func toggleExternalSearchProviderExpansion(_ provider: ExternalSearchProviderID) {
        if expandedExternalSearchProviders.contains(provider) {
            expandedExternalSearchProviders.remove(provider)
        } else {
            expandedExternalSearchProviders.insert(provider)
        }
    }

    private var aggregateExternalContextBinding: Binding<Bool> {
        Binding(
            get: { settings.aggregateExternalContextSearchEnabled },
            set: { settings.aggregateExternalContextSearchEnabled = $0 }
        )
    }

    private func providerEnabledBinding(_ provider: ExternalSearchProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.externalSearchSettings(for: provider).isEnabled },
            set: { newValue in
                var providerSettings = settings.externalSearchSettings(for: provider)
                guard !newValue || canToggleProviderOn(provider) else { return }
                providerSettings.isEnabled = newValue
                settings.setExternalSearchSettings(providerSettings, for: provider)
            }
        )
    }

    private func providerAnonymousBinding(_ provider: ExternalSearchProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.externalSearchSettings(for: provider).anonymousMode },
            set: { newValue in
                var providerSettings = settings.externalSearchSettings(for: provider)
                providerSettings.anonymousMode = newValue
                settings.setExternalSearchSettings(providerSettings, for: provider)
            }
        )
    }

    private func providerFetchFullTextBinding(_ provider: ExternalSearchProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.externalSearchSettings(for: provider).fetchFullText },
            set: { newValue in
                var providerSettings = settings.externalSearchSettings(for: provider)
                providerSettings.fetchFullText = newValue
                settings.setExternalSearchSettings(providerSettings, for: provider)
            }
        )
    }

    private func apiKeyBinding(_ provider: ExternalSearchProviderID) -> Binding<String> {
        Binding(
            get: { externalSearchAPIKeys[provider] ?? "" },
            set: { newValue in
                externalSearchAPIKeys[provider] = newValue
                externalSearchAPIKeyTestStates[provider] = .idle
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    settings.setExternalSearchAPIKey(nil, for: provider)
                } else {
                    settings.clearExternalSearchCredentialVerification(for: provider)
                }
            }
        )
    }

    private func canToggleProviderOn(_ provider: ExternalSearchProviderID) -> Bool {
        let providerSettings = settings.externalSearchSettings(for: provider)
        if provider.supportsAnonymous, providerSettings.anonymousMode { return true }
        return providerSettings.hasVerifiedCredential && settings.externalSearchAPIKey(for: provider)?.isEmpty == false
    }

    private func apiKeyDraft(for provider: ExternalSearchProviderID) -> String {
        (externalSearchAPIKeys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 各 Provider 官方 API Key 管理入口。
    ///
    /// 这些 URL 来自对应服务的官方文档 / 控制台入口,集中维护是为了避免 UI 中散落
    /// 字符串,后续服务方改 dashboard 路径时只需要更新这一处。
    private func externalSearchAPIKeyURL(for provider: ExternalSearchProviderID) -> URL {
        switch provider {
        case .anySearch:
            return URL(string: "https://anysearch.com/console/api-keys")!
        case .tavily:
            return URL(string: "https://app.tavily.com")!
        case .exa:
            return URL(string: "https://dashboard.exa.ai/api-keys")!
        case .braveLLMContext:
            return URL(string: "https://api-dashboard.search.brave.com")!
        case .firecrawl:
            return URL(string: "https://www.firecrawl.dev/app/api-keys")!
        }
    }

    private func toggleAPIKeyVisibility(_ provider: ExternalSearchProviderID) {
        if visibleExternalSearchAPIKeys.contains(provider) {
            visibleExternalSearchAPIKeys.remove(provider)
        } else {
            visibleExternalSearchAPIKeys.insert(provider)
        }
    }

    private func loadExternalSearchAPIKeys() {
        externalSearchAPIKeys = Dictionary(uniqueKeysWithValues: ExternalSearchProviderID.allCases.map { provider in
            (provider, settings.externalSearchAPIKey(for: provider) ?? "")
        })
    }

    /// 测试按钮是否可点：匿名（keyless）模式无需 key；认证模式要求已输入 key。
    private func canTestExternalSearchKey(_ provider: ExternalSearchProviderID) -> Bool {
        if externalSearchAPIKeyTestStates[provider] == .testing { return false }
        let providerSettings = settings.externalSearchSettings(for: provider)
        if provider.supportsAnonymous, providerSettings.anonymousMode {
            return true
        }
        return !apiKeyDraft(for: provider).isEmpty
    }

    /// 使用输入框中的未保存 Key 发起真实 credential test。探测成功后才持久化；
    /// 失败时不保存候选 Key，也不自动启用 Provider。
    private func testExternalSearchAPIKey(_ provider: ExternalSearchProviderID) {
        let candidate = apiKeyDraft(for: provider)
        let providerSettings = settings.externalSearchSettings(for: provider)
        let anonymous = provider.supportsAnonymous && providerSettings.anonymousMode
        // 匿名（keyless）模式允许空 key；认证模式要求 key。
        guard anonymous || !candidate.isEmpty else { return }

        externalSearchAPIKeyTestStates[provider] = .testing
        Task {
            let tester = ExternalSearchCredentialTester(settings: settings)
            switch await tester.test(provider: provider, candidateKey: candidate, anonymous: anonymous) {
            case .succeeded:
                externalSearchAPIKeys[provider] = candidate
                externalSearchAPIKeyTestStates[provider] = .succeeded
            case .saveFailed:
                externalSearchAPIKeyTestStates[provider] = .saveFailed
            case .failed(let failure):
                externalSearchAPIKeyTestStates[provider] = .failed(
                    failure.friendlyMessage,
                    failure.technicalDetails
                )
            }
        }
    }

    @ViewBuilder
    private func externalSearchAPIKeyTestFeedback(_ provider: ExternalSearchProviderID) -> some View {
        switch externalSearchAPIKeyTestStates[provider] ?? .idle {
        case .idle, .testing:
            EmptyView()
        case .succeeded:
            Label("settings.externalSearch.apiKey.testSucceeded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .saveFailed:
            Label("settings.externalSearch.apiKey.saveFailed", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .failed(let message, let details):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if let details {
                    let isExpanded = expandedExternalSearchTechnicalDetails.contains(provider)
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { isExpanded },
                            set: { expanded in
                                if expanded { expandedExternalSearchTechnicalDetails.insert(provider) }
                                else { expandedExternalSearchTechnicalDetails.remove(provider) }
                            }
                        )
                    ) {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Button {
                            if isExpanded { expandedExternalSearchTechnicalDetails.remove(provider) }
                            else { expandedExternalSearchTechnicalDetails.insert(provider) }
                        } label: {
                            HStack {
                                Text("settings.externalSearch.apiKey.technicalDetails")
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                    .font(.caption)
                }
            }
        }
    }

    /// Provider 凭据测试只属于当前设置视图，不向业务层暴露瞬时 UI 状态。
    private enum APIKeyTestState: Equatable {
        case idle
        case testing
        case succeeded
        case saveFailed
        case failed(String, String?)
    }
}
