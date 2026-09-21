//
//  AgentAssistantMessageContentView.swift
//  Starcat
//
//  按 Provider 已结算的原始 block 顺序展示 Agent reasoning 与正文。
//

import SwiftUI

/// 一个稳定的已结算 assistant 消息节点。
///
/// 该 View 只接收 settled message，不接收逐 token delta。配合 `EquatableView`，Trace
/// 状态、选中项或 usage 变化不会让已经完成的 Markdown 再次参与差异计算；reasoning
/// 正文默认折叠，也不会在长 Run 首次布局时测量全部思考文本。
struct AgentAssistantMessageContentView: View, Equatable {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    private let visibleParts: [AgentMessagePart]

    init(parts: [AgentMessagePart], fallbackText: String) {
        let orderedParts = parts.compactMap { part -> AgentMessagePart? in
            switch part {
            case .reasoning(let text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : .reasoning(text)
            case .text(let text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : .text(text)
            case .toolCall, .toolResult:
                // 工具由 Runtime Trace 的专用行展示，不能在 assistant 正文里重复生成卡片。
                return nil
            }
        }
        if orderedParts.isEmpty,
           !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            visibleParts = [.text(fallbackText)]
        } else {
            visibleParts = orderedParts
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleParts.indices, id: \.self) { index in
                switch visibleParts[index] {
                case .reasoning(let reasoning):
                    DisclosureGroup {
                        Text(reasoning)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineSpacing(2)
                            .padding(.top, 5)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "brain")
                                .font(interfaceScale.font(.captionSmall))
                                .foregroundStyle(.secondary)
                            Text("agent.workspace.trace.kind.thinking")
                                .font(interfaceScale.font(.caption, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(Self.summary(reasoning))
                                .font(interfaceScale.font(.captionSmall))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                case .text(let text):
                    RAGMarkdownText(content: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .toolCall, .toolResult:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 折叠态只取第一行且设置上限，避免把完整 reasoning 复制进标题并参与反复测量。
    private static func summary(_ reasoning: String) -> String {
        let firstLine = reasoning.split(whereSeparator: \.isNewline).first.map(String.init) ?? reasoning
        return String(firstLine.prefix(160))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visibleParts == rhs.visibleParts
    }
}
