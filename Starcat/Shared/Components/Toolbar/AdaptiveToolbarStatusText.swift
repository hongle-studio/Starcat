//
//  AdaptiveToolbarStatusText.swift
//  Starcat
//
//  中栏顶栏辅助描述的空间退让规则；不重建相邻按钮，保留刷新动效和菜单状态。
//

import SwiftUI

/// 文字能完整容纳时才显示；错误 / 陈旧警告可声明为必需，不参与隐藏。
/// 同排 Spacer 必须使用 spacerPriority，让按钮先获得空间、描述其次、留白最后。
struct AdaptiveToolbarStatusText: View {
    let text: String
    var isRequired = false

    static let spacerPriority: Double = -2
    var priority: Double { isRequired ? 0 : -1 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // 固定文字理想宽度，避免被换行或截断后误判为“能够完整显示”。
            Text(text)
                .fixedSize(horizontal: true, vertical: false)
            if !isRequired {
                // EmptyView 不参与布局；零尺寸的实体视图才是可供选择的隐藏分支。
                Color.clear
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .layoutPriority(priority)
    }

    /// 隐藏描述只改变视觉密度，完整说明仍放在原刷新提示之后，不替换操作语义。
    static func refreshTooltip(action: String, status: String?) -> String {
        guard let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return action }
        return "\(action)\n\(status)"
    }
}
