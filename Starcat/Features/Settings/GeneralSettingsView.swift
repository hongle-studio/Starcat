//
//  GeneralSettingsView.swift
//  Starcat
//
//  主设置的通用页：说明用途、按使用场景组织表单，直接绑定现有偏好。
//  页面只负责呈现，不新增配置副本，不改变即时保存、渠道门控与重置入口。
//

import AppKit
import SwiftUI

/// 独立承载通用表单，避免后续设置页调整继续膨胀主导航的视图与状态。
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var localeStore = LocaleStore.shared
    @State private var isAdvancedExpanded = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            introductionSection
            appearanceSection
            macOSIntegrationSection

            // 感兴趣语言是长期候选池，保持在 macOS 集成之后，不与显示语言混排。
            InterestedLanguagesSettingsSection(languages: $settings.interestedLanguages)

            if DistributionChannel.current.isDirect {
                directUpdateSection
            }

            advancedSection
        }
        .formStyle(.grouped)
    }

    /// 原生 grouped Section 本身提供卡片表面；这里不再嵌套自绘背景或固定高度。
    private var introductionSection: some View {
        Section {
            HStack(spacing: 16) {
                // 分类说明卡片按设计使用蓝色齿轮标识身份，普通 Section 图标仍沿用原有样式。
                Image(systemName: "gearshape.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.general.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("settings.general.introduction.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text("settings.general.introduction.description"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    /// 控件与说明合为同一表单行，减少原先每段说明独占一行造成的留白。
    private var appearanceSection: some View {
        @Bindable var settings = settings

        return Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    Picker("settings.general.appearanceMode", selection: appearanceSelection) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } label: {
                    Text("settings.general.appearanceMode")
                }

                Text("settings.general.appearanceMode.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    Picker("settings.general.interfaceScale", selection: $settings.interfaceScale) {
                        ForEach(InterfaceScale.allCases) { scale in
                            Text(scale.displayName).tag(scale)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } label: {
                    Text("settings.general.interfaceScale")
                }

                Text("settings.general.interfaceScale.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            languagePreferenceRow

            // 减少动画影响使用舒适度，保持常驻；这里只合并呈现，不改变系统偏好的叠加逻辑。
            preferenceToggle(
                "settings.general.disableAnimations.title",
                description: "settings.general.disableAnimations.help",
                isOn: $settings.disableAnimations
            )
        } header: {
            SettingsSectionHeader("settings.general.appearanceAndLanguage.title", systemImage: "paintbrush.fill")
        }
    }

    /// 保留主题切换的既有动画；系统或应用要求减少动态效果时立即生效。
    private var appearanceSelection: Binding<AppearanceMode> {
        Binding(
            get: { settings.appearanceMode },
            set: { newValue in
                if reduceMotion {
                    settings.appearanceMode = newValue
                } else {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        settings.appearanceMode = newValue
                    }
                }
            }
        )
    }

    /// 语言仍使用母语名称与 LocaleStore；不复制选择状态或改变菜单重启边界。
    private var languagePreferenceRow: some View {
        @Bindable var localeStore = localeStore

        return VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $localeStore.selection) {
                ForEach(AppLocale.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            } label: {
                Text("settings.general.language.label")
            }
            .pickerStyle(.menu)

            Text("settings.general.language.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detailBehaviorRows: some View {
        @Bindable var settings = settings

        return Group {
            preferenceToggle(
                "settings.general.openFirstDetailOnCategoryChange.title",
                description: "settings.general.openFirstDetailOnCategoryChange.help",
                isOn: $settings.openFirstDetailOnCategoryChange
            )
            preferenceToggle(
                "settings.general.openRepositoryMarkdownInApp.title",
                description: "settings.general.openRepositoryMarkdownInApp.help",
                isOn: $settings.openRepositoryMarkdownInApp
            )
            preferenceToggle(
                "settings.activity.issueEvents.title",
                description: "settings.activity.issueEvents.help",
                isOn: $settings.githubIssueEventTimelineEnabled
            )
        }
    }

    private var macOSIntegrationSection: some View {
        @Bindable var settings = settings

        return Section {
            preferenceToggle(
                "settings.general.hideDockIcon.title",
                description: "settings.general.hideDockIcon.help",
                isOn: $settings.hideDockIcon
            )
            preferenceToggle(
                "settings.general.spotlightSearch.title",
                description: "settings.general.spotlightSearch.help",
                isOn: $settings.spotlightSearchEnabled
            )

            if DistributionChannel.current.isDirect {
                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.general.screensaver.title")
                    Text("settings.general.screensaver.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScreensaverSettingsSection()
                }
            }
        } header: {
            SettingsSectionHeader("settings.general.macOSIntegration", systemImage: "macwindow.on.rectangle")
        }
    }

    /// 低频偏好只折叠呈现，展开后仍是原生表单行，避免多层卡片与配置副本。
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                Text("settings.general.detailBehavior")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                detailBehaviorRows

                Divider()

                Text("settings.general.advanced.effects.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                contributionStyleRow

                Divider()

                Text("settings.general.reset")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                preferenceResetRows
            } label: {
                // 原生 chevron 保留展开语义；label 使用全宽 Button，文字和空白均可切换。
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        isAdvancedExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "slider.horizontal.3")
                                .font(SettingsIconMetrics.smallGlyph)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                            Text("settings.general.advanced.title")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .help(Text("settings.general.advanced.title"))
                        }
                        Text("settings.general.advanced.summary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(Text("settings.general.advanced.summary"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(Text("settings.general.advanced.title"))
                .accessibilityValue(Text(LocalizedStringKey(isAdvancedExpanded
                                                            ? "settings.general.disclosure.expanded"
                                                            : "settings.general.disclosure.collapsed")))
            }
        }
    }

    private var contributionStyleRow: some View {
        @Bindable var settings = settings

        return VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $settings.snakeStyle) {
                ForEach(SnakeStyle.allCases) { style in
                    Label(LocalizedStringKey(style.displayNameKey), systemImage: style.systemImage)
                        .tag(style)
                }
            } label: {
                Text("settings.snakeStyle.title")
            }
            .pickerStyle(.menu)

            Text("settings.snakeStyle.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 所有说明跟随对应开关，不增加一个需要保存的表单草稿层。
    private func preferenceToggle(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Sparkle 配置仅在 Direct 页挂载，继续使用现有控制器与可用性判定。
    private var directUpdateSection: some View {
        let updateController = dependencies.directUpdateController

        return Section {
            Picker("settings.pro.direct.updates.channel", selection: Binding(
                get: { updateController.updateChannel },
                set: { updateController.selectUpdateChannel($0) }
            )) {
                Text("settings.general.updates.channel.stable")
                    .tag(DirectUpdateChannel.stable)
                Text("settings.general.updates.channel.preview")
                    .tag(DirectUpdateChannel.development)
            }

            if updateController.updateChannel == .development {
                Text("settings.general.updates.channel.preview.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("settings.pro.direct.updates.autoCheck", isOn: Binding(
                get: { updateController.automaticallyChecksForUpdates },
                set: { updateController.automaticallyChecksForUpdates = $0 }
            ))
            .disabled(!updateController.isConfigured)

            Toggle("settings.pro.direct.updates.autoDownload", isOn: Binding(
                get: { updateController.automaticallyDownloadsUpdates },
                set: { updateController.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!updateController.isConfigured || !updateController.automaticallyChecksForUpdates)

            HStack {
                Spacer()
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Label("settings.pro.direct.updates.check", systemImage: "arrow.triangle.2.circlepath")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!updateController.canCheckForUpdates)
            }
        } header: {
            SettingsSectionHeader("settings.pro.direct.updates.section", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            // 已配置时不再展示自动下载说明；仅保留未配置时解释更新检查为何禁用的提示。
            if !updateController.isConfigured {
                Text("settings.pro.direct.updates.notConfigured")
            }
        }
    }

    /// 左侧说明重置对象，右侧统一图标入口；这些动作仍由既有确认或引导流程完成。
    private var preferenceResetRows: some View {
        Group {
            LabeledContent {
                ResetIconButton(
                    help: Text("settings.listPreferences.reset.title"),
                    showsSuccessFeedback: false,
                    action: resetListPreferences
                )
                .disabled(!dependencies.authSession.state.isAuthenticated)
                .help(Text(LocalizedStringKey(dependencies.authSession.state.isAuthenticated
                                             ? "settings.listPreferences.reset.title"
                                             : "settings.listPreferences.reset.disabled")))
            } label: {
                Text("settings.listPreferences.reset.title")
                    .lineLimit(1)
                    .help(Text("settings.listPreferences.reset.title"))
            }

            LabeledContent {
                ResetIconButton(
                    help: Text("settings.general.resetOnboarding.label"),
                    showsSuccessFeedback: false,
                    action: replayOnboarding
                )
                .disabled(!FirstRunOnboardingPreferences.canReplayManually)
            } label: {
                Text("settings.general.resetOnboarding.label")
                    .lineLimit(1)
                    .help(Text("settings.general.resetOnboarding.label"))
            }
        }
    }

    /// 保留原通知路由；列表侧负责确认与重置范围，通用页不直接清空偏好。
    private func resetListPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .starcatResetListPreferencesRequested, object: nil)
    }

    /// 关闭设置后复用原引导流程，不在通用页重新创建一套引导状态。
    private func replayOnboarding() {
        guard FirstRunOnboardingPreferences.canReplayManually else { return }
        NSApp.keyWindow?.close()
        FirstRunOnboardingPreferences.requestManualReplay()
    }
}
