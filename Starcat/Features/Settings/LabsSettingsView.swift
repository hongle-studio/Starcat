//
//  LabsSettingsView.swift
//  Starcat
//
//  设置页 → 实验性功能(Labs)Tab。
//
//  定位:
//  - 实验性能力的统一开关入口:当前仅有 TypeSafe Jev 决策引擎(2026-09-18 POC),
//    后续新实验也落在本页,与稳定功能隔离,便于整体下线;
//  - 本页只做「配置 + 探测」,不持有任何业务装配(路由器在 AppDependencies);
//  - 「测试连接」同时是 POC 的速度验证入口:发一次真实 Noul 决策,
//    显示往返延迟与返回概率,让 dong4j 无需跑整理流程就能感知 Jev 速度。
//
//  关键约束:
//  - API Key 走 `KeychainManager` service key 机制(serviceID = typesafe-ai),
//    草稿编辑不落盘,「测试连接」成功才持久化(与 ServicesSettings 的
//    「保存合并进测试」约定一致);清空输入框立即删除已存 Key;
//  - 测试失败不保存、不自动开启任何开关。
//

import SwiftUI

struct LabsSettingsTab: View {

    @Environment(AppSettings.self) private var settings

    @State private var draftAPIKey = ""
    @State private var revealAPIKey = false
    @State private var testState: TestState = .idle

    /// 测试连接的会话级结果;不写入任何持久化。
    private enum TestState: Equatable {
        case idle
        case testing
        case succeeded(elapsedMilliseconds: Int, noul: Double)
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Text("settings.labs.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            typeSafeSection
        }
        .formStyle(.grouped)
        .task {
            loadStoredAPIKey()
        }
        .onChange(of: draftAPIKey) { _, newValue in
            testState = .idle
            // 清空草稿 = 删除已存 Key(与 ExternalSearch 的编辑语义一致);
            // 非空编辑只停留在草稿,等「测试连接」成功才落盘。
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? KeychainManager.shared.deleteServiceAPIKey(
                    forService: TypeSafeDecisionService.keychainServiceID
                )
            }
        }
    }

    // MARK: - TypeSafe Jev 决策引擎

    private var typeSafeSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("settings.labs.typesafe.enable", isOn: $settings.typesafeDecisionEnabled)
            Text("settings.labs.typesafe.enable.description")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.typesafeDecisionEnabled {
                // Key 未配置时给出显式回退提示:开关已开但所有路由仍在走 LLM。
                if storedOrDraftKeyIsEmpty {
                    Label("settings.labs.typesafe.noKey", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                apiKeyRows

                modelRow

                testConnectionRow

                Toggle("settings.labs.typesafe.grouping", isOn: $settings.typesafeGroupingSuggestionsEnabled)
                Text("settings.labs.typesafe.grouping.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("settings.labs.typesafe.tags", isOn: $settings.typesafeTagSuggestionsEnabled)
                Text("settings.labs.typesafe.tags.hybrid.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("settings.labs.typesafe.scope.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeader(
                "settings.labs.typesafe.section",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    // MARK: - API Key 行

    @ViewBuilder
    private var apiKeyRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("settings.labs.typesafe.apiKey")
                    .font(.callout.weight(.medium))
                Spacer()
                Link("settings.labs.typesafe.apiKey.get", destination: Self.consoleKeysURL)
                    .font(.caption.weight(.medium))
            }

            HStack(spacing: 8) {
                Group {
                    if revealAPIKey {
                        TextField("", text: $draftAPIKey, prompt: Text("settings.labs.typesafe.apiKey.placeholder"))
                    } else {
                        SecureField("", text: $draftAPIKey, prompt: Text("settings.labs.typesafe.apiKey.placeholder"))
                    }
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .id(revealAPIKey)

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
            }
        }
    }

    // MARK: - 模型行

    private var modelRow: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 4) {
            Text("settings.labs.typesafe.model")
                .font(.callout.weight(.medium))
            TextField(
                "",
                text: $settings.typesafeModelID,
                prompt: Text(TypeSafeDecisionService.defaultModelID)
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            Text("settings.labs.typesafe.model.description")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 测试连接

    /// 独立操作按钮按设置页规范右对齐;结果与错误留在同行左侧。
    private var testConnectionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            testFeedback
            Spacer(minLength: 8)

            Button {
                testConnection()
            } label: {
                if testState == .testing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("settings.labs.typesafe.test")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize()
            .disabled(!canTest)
        }
    }

    @ViewBuilder
    private var testFeedback: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case let .succeeded(milliseconds, noul):
            Label(
                title: {
                    Text(
                        String(
                            format: String.l10n("settings.labs.typesafe.test.successFormat"),
                            NSNumber(value: milliseconds),
                            String(format: "%.2f", noul)
                        )
                    )
                },
                icon: { Image(systemName: "checkmark.circle.fill") }
            )
            .font(.caption)
            .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    // MARK: - 动作

    private static let consoleKeysURL = URL(string: "https://console.typesafe.ai/settings/keys")!

    private var storedOrDraftKeyIsEmpty: Bool {
        trimmedDraftKey.isEmpty
    }

    private var trimmedDraftKey: String {
        draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canTest: Bool {
        testState != .testing && !trimmedDraftKey.isEmpty
    }

    private func loadStoredAPIKey() {
        draftAPIKey = (try? KeychainManager.shared.loadServiceAPIKey(
            forService: TypeSafeDecisionService.keychainServiceID
        )) ?? ""
    }

    /// 用草稿 Key 发一次真实 Noul 决策(同时验证鉴权与决策延迟)。
    /// 成功才落盘;失败不保存、不改开关。清空草稿时立即删除已存 Key。
    private func testConnection() {
        let candidate = trimmedDraftKey
        guard !candidate.isEmpty else { return }
        testState = .testing

        Task {
            // 探测用一次性 client:不依赖 AppDependencies 装配,设置页可独立使用。
            let client = TypeSafeClient()
            let clock = ContinuousClock()
            do {
                let start = clock.now
                let response = try await client.evaluate(
                    state: "Starcat is a native macOS application for managing GitHub stars.",
                    model: resolvedModelID,
                    questions: [
                        "demo": .noul(
                            instructions: "Does this text describe a software product?",
                            criteria: nil
                        )
                    ],
                    apiKey: candidate,
                    operation: .connectionTest
                )
                let elapsed = clock.now - start
                let milliseconds = Int(elapsed.components.seconds) * 1_000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

                guard let noul = response.answers["demo"]?.noul, noul.isFinite else {
                    testState = .failed(String.l10n("settings.labs.typesafe.test.missingAnswer"))
                    return
                }
                try? KeychainManager.shared.storeServiceAPIKey(
                    candidate,
                    forService: TypeSafeDecisionService.keychainServiceID
                )
                testState = .succeeded(elapsedMilliseconds: milliseconds, noul: noul)
            } catch is CancellationError {
                testState = .idle
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }

    private var resolvedModelID: String {
        let trimmed = settings.typesafeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? TypeSafeDecisionService.defaultModelID : trimmed
    }
}
