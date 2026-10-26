//
//  RepoLicenseFilterChip.swift
//  Starcat
//
//  许可证筛选的纯展示按钮；与左侧标签共享胶囊外观，不持有额外的选择状态。
//

import SwiftUI

/// 许可证按已确认的义务类型着色，“全部”使用强调色；外观尺寸与左侧标签一致。
struct RepoLicenseFilterChip: View {
    let title: String
    let isSelected: Bool
    let category: RepoLicenseCategory?
    let action: () -> Void
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    init(title: String, isSelected: Bool, category: RepoLicenseCategory? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.category = category
        self.action = action
    }

    private var swatchColor: Color { category?.color ?? .accentColor }

    /// 保留完整协议名，分类说明不进入布局，避免长说明撑宽胶囊。
    private var helpText: Text {
        guard let category else { return Text(verbatim: title) }
        return Text(verbatim: title + "\n") + Text(category.helpKey)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelected && differentiateWithoutColor ? "checkmark" : "tag.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 11)
                    // 与左侧标签一致：未选中图标保留颜色，选中后与实色底形成对比。
                    .foregroundStyle(isSelected ? TagChipSurface.selectedForeground(for: swatchColor) : swatchColor)
                Text(verbatim: title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .modifier(TagChipSurface(color: swatchColor, isSelected: isSelected))
            // 动画只作用于当前胶囊的外观，不给整个筛选浮层附加布局动画。
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: TagChipSurface.cornerRadius))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(helpText)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(category.map { Text($0.helpKey) } ?? Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .pressableHover(scale: 1)
    }
}
