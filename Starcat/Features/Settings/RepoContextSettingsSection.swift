//
//  RepoContextSettingsSection.swift
//  Starcat
//
//  代码与本地工具中的代码上下文配置与产物管理。
//  复用 AppSettings 和 RepoContextStorage，页面迁移不改变配置值及文件访问规则。
//

import AppKit
import SwiftUI

/// 独立承载代码上下文的绑定、目录操作和错误反馈，避免依赖 AI 设置页生命周期。
struct RepoContextSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var aiContextStorage = RepoContextStorage.shared
    @State private var aiContextActionError: String?

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

    var body: some View {
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
        // 进入本功能所在页面时刷新产物摘要；与其他本地工具的扫描各自独立。
        .task { aiContextStorage.reload() }
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

    /// 总开关沿用原配置绑定，迁移页面不改变持久化字段和开关行为。
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

}
