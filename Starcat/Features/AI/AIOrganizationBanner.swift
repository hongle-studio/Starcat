//
//  AIOrganizationBanner.swift
//  Starcat
//
//  未分组 / 未分类共用的后台任务入口；长翻译不能改变横幅高度或挤走操作。
//

import SwiftUI
import ThinkingOrbsKit

/// 只展示会话投影；单行文本截断、完整 tooltip、窄宽图标入口共同保证多语言布局稳定。
struct AIOrganizationBanner: View {
    enum Kind { case grouping, tags }

    let kind: Kind
    let repositoryCount: Int
    let state: AIOrganizationBannerState
    let canStart: Bool
    let onStart: () -> Void
    let onShowPanel: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.tint.opacity(0.18))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 完整按钮必须按自然单行宽度参与适配；空间不足换图标，而不是让按钮文字换行。
    private func row(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if case .analyzing = state {
                ThinkingOrb(state: .composing, size: .px20, theme: .auto, paused: reduceMotion)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: state.statusIcon)
                    .font(interfaceScale.font(.body))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(interfaceScale.font(.rowTitle, weight: .medium))
                    .help(Text(verbatim: title))
                Text(verbatim: detail)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(Text(verbatim: detail))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: compact ? 0 : interfaceScale.scaled(120), maxWidth: .infinity, alignment: .leading)

            Button(action: state == .idle ? onStart : onShowPanel) {
                if compact {
                    Label { Text(verbatim: AIOrganizationBannerText.l10n(state.actionKey)) } icon: {
                        Image(systemName: state == .idle ? "play.fill" : "macwindow")
                    }
                        .labelStyle(.iconOnly)
                } else {
                    Label { Text(verbatim: AIOrganizationBannerText.l10n(state.actionKey)) } icon: {
                        Image(systemName: state == .idle ? "play.fill" : "macwindow")
                    }
                        .lineLimit(1)
                }
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(state == .idle && !canStart)
            .help(Text(verbatim: AIOrganizationBannerText.l10n(state.actionKey)))
        }
        .frame(height: interfaceScale.scaled(36))
    }

    private var title: String {
        switch state {
        case .idle:
            String(format: String.l10n(kind == .grouping ? "githubStarLists.ungroupedBanner.titleFormat" : "batchAI.banner.titleFormat"), repositoryCount)
        case .preparing: AIOrganizationBannerText.l10n("aiOrganization.banner.preparing")
        case .analyzing: AIOrganizationBannerText.l10n("aiOrganization.banner.analyzing")
        case .applying: AIOrganizationBannerText.l10n(kind == .grouping ? "aiOrganization.banner.applyingGroups" : "aiOrganization.banner.applyingTags")
        case .paused: AIOrganizationBannerText.l10n("aiOrganization.banner.paused")
        case .review(let count): count > 0 ? formatted("aiOrganization.banner.pendingFormat", count) : AIOrganizationBannerText.l10n("aiOrganization.banner.review")
        case .failed(let count): count > 0 ? formatted("aiOrganization.banner.failedFormat", count) : AIOrganizationBannerText.l10n("aiOrganization.banner.failure")
        }
    }

    private var detail: String {
        switch state {
        case .idle: String.l10n(kind == .grouping ? "githubStarLists.ungroupedBanner.hint" : "batchAI.banner.hint")
        case .preparing: AIOrganizationBannerText.l10n("aiOrganization.banner.backgroundHint")
        case let .analyzing(processed, total), let .paused(processed, total):
            formatted("aiOrganization.banner.analyzedFormat", processed, total)
        case let .applying(processed, total):
            total > 0 ? formatted("aiOrganization.banner.processedFormat", processed, total) : AIOrganizationBannerText.l10n("aiOrganization.banner.preparingApplication")
        case .review: AIOrganizationBannerText.l10n("aiOrganization.banner.reviewHint")
        case .failed: AIOrganizationBannerText.l10n("aiOrganization.banner.failureHint")
        }
    }

    /// 数字按界面 locale 格式化，模板保留参数顺序供不同语言调整语序。
    private func formatted(_ key: String, _ values: Int...) -> String {
        String(format: AIOrganizationBannerText.l10n(key), arguments: values.map { $0.formatted(.number.locale(locale)) })
    }
}
