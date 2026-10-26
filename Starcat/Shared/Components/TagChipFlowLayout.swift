//
//  TagChipFlowLayout.swift
//  Starcat
//
//  从左侧标签墙提取的内容宽度换行布局；默认保持原有测量与放置规则。
//

import SwiftUI

/// 默认不约束单个标签，保持左侧标签墙原样；窄浮层可约束长文本，使其在行内截断。
struct TagChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var constrainsItemWidth = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let itemProposal = measurementProposal(width: maxWidth)
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(itemProposal)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let itemProposal = measurementProposal(width: bounds.width)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(itemProposal)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// 测量与放置使用同一宽度提案；长名称只在启用约束的许可证浮层内截断。
    private func measurementProposal(width: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: constrainsItemWidth && width.isFinite ? max(width, 0) : nil, height: nil)
    }
}
