//
//  JevConnectionSettingsView.swift
//  Starcat
//
//  决策引擎卡片内的 Jev 配置：受控模型选择、同行测试反馈与紧凑备用连接。
//  备用路由或测试失败均不能替换原生模型选择器。
//

import SwiftUI

/// 模型状态由设置页持有，本视图切换显示时不丢失凭据草稿或测试结果。
struct JevConnectionSettingsView: View {
    @Bindable var model: JevConnectionSettingsModel
    @State private var revealAPIKey = false

    private static let labelWidth: CGFloat = 150
    private static let consoleKeysURL = URL(string: "https://console.typesafe.ai/settings/keys")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("settings.labs.typesafe.section", systemImage: "network")
                .font(.callout.weight(.semibold))
            apiKeyRows
            modelRow
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    testFeedback
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                Button {
                    Task { await model.testConnection() }
                } label: {
                    HStack(spacing: 6) {
                        if model.testState == .testing {
                            ProgressView().controlSize(.small)
                        }
                        Text("settings.labs.typesafe.test")
                    }
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(!model.canTest)
            }
            Divider()
            connectionStatus
        }
        .task(id: model.draftAPIKey) {
            // 输入 Key 时做短暂防抖；取消的任务不能继续获取或覆盖新 Key 的候选。
            do {
                try await Task.sleep(for: .milliseconds(500))
                await model.refreshModels()
            } catch {}
        }
    }

    /// 两行使用相同标题列与输入列；标题按整行中心对齐，长语言允许自然增高。
    private var apiKeyRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                fieldLabel("settings.labs.typesafe.apiKey.optional")
                HStack(spacing: 8) {
                    Group {
                        if revealAPIKey {
                            TextField("", text: $model.draftAPIKey, prompt: Text("settings.labs.typesafe.apiKey.placeholder"))
                        } else {
                            SecureField("", text: $model.draftAPIKey, prompt: Text("settings.labs.typesafe.apiKey.placeholder"))
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("settings.labs.typesafe.apiKey.optional"))
                    Button {
                        revealAPIKey.toggle()
                    } label: {
                        Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                            .font(SettingsIconMetrics.standardGlyph)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(revealAPIKey ? "settings.labs.typesafe.apiKey.hide" : "settings.labs.typesafe.apiKey.reveal")
                    .accessibilityLabel(Text(revealAPIKey ? "settings.labs.typesafe.apiKey.hide" : "settings.labs.typesafe.apiKey.reveal"))
                }
            }
            HStack(alignment: .center, spacing: 12) {
                Color.clear.frame(width: Self.labelWidth, height: 1).accessibilityHidden(true)
                Spacer(minLength: 0)
                Link("settings.labs.typesafe.apiKey.get", destination: Self.consoleKeysURL)
                    .font(.caption)
                    .fixedSize()
            }
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                fieldLabel("settings.labs.layout.modelVersion")
                // 保留旧值的占位项，避免列表没返回该版本时静默改写用户配置。
                Picker("settings.labs.layout.modelVersion", selection: $model.nativeModelID) {
                    if !model.hasAvailableModelSelection {
                        (Text(verbatim: model.nativeModelID) + Text("settings.labs.models.reselect"))
                            .tag(model.nativeModelID)
                            .disabled(true)
                    }
                    ForEach(model.availableModelIDs, id: \.self) { id in
                        Text(verbatim: id).tag(id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: model.nativeModelID))
                .frame(maxWidth: .infinity, alignment: .trailing)
                SyncIconButton(
                    isRefreshing: model.isLoadingModels,
                    disabled: model.isLoadingModels
                        || model.draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    tooltip: String.l10n("settings.labs.models.refresh")
                ) {
                    Task { await model.refreshModels() }
                }
                .accessibilityLabel(Text("settings.labs.models.refresh"))
                .frame(width: 28, height: 28)
            }
            if model.modelListFailed {
                Text("settings.labs.models.loadFailed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var testFeedback: some View {
        if let message = model.nativeFailureMessage, !testFailed {
            feedback(
                title: Text("settings.labs.layout.nativeFailure"),
                message: Text(verbatim: message),
                success: false
            )
        }
        switch model.testState {
        case .idle, .testing:
            EmptyView()
        case let .succeeded(source, milliseconds, noul):
            feedback(title: successFeedback(source, milliseconds: milliseconds, noul: noul), success: true)
        case .failed(let message):
            if model.nativeFailureMessage != nil {
                feedback(
                    title: Text("settings.labs.layout.nativeFailure"),
                    message: Text(verbatim: message), success: false
                )
            } else {
                feedback(title: Text(verbatim: message), success: false)
            }
        }
    }

    private var testFailed: Bool {
        if case .failed = model.testState { return true }
        return false
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("settings.labs.models.fallback")
                    .help(Text("settings.labs.models.fallback"))
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.openRouterFallback == nil ? Color.secondary : Color.green)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(fallbackStatus)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(Text(fallbackStatus))
                }
                Text(verbatim: "OpenRouter")
                Text(verbatim: JevDecisionEngine.openRouterModelID)
                    .monospaced()
                    .lineLimit(1)
                    .fixedSize()
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text("settings.labs.layout.fallbackHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.hasUsableCredential {
                Label("settings.labs.typesafe.noAvailableRoute", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 8)
                Button("settings.labs.layout.manageProviders") {
                    NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.models")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var fallbackStatus: LocalizedStringKey {
        if model.openRouterFallback == nil { return "settings.labs.layout.fallbackMissing" }
        return model.isUsingOpenRouter ? "settings.labs.layout.fallbackActive" : "settings.labs.layout.fallbackReady"
    }

    private func fieldLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .frame(width: Self.labelWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func feedback(title: Text, message: Text? = nil, success: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 4) {
                title
                if let message { message.foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func successFeedback(
        _ source: JevDecisionAccess.Source, milliseconds: Int, noul: Double
    ) -> Text {
        let probability = String(format: "%.2f", noul)
        switch source {
        case .typeSafe:
            return Text(verbatim: String(
                format: String.l10n("settings.labs.typesafe.test.successFormat"),
                NSNumber(value: milliseconds), probability
            ))
        case let .openRouter(_, displayName):
            return Text(verbatim: String(
                format: String.l10n("settings.labs.typesafe.test.openRouterSuccessFormat"),
                displayName, NSNumber(value: milliseconds), probability
            ))
        }
    }
}
