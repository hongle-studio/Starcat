//
//  RepoLicenseFilterSection.swift
//  Starcat
//
//  现有全局筛选浮层内的许可证标签墙；按内容收缩，超过约四行时在区内滚动。
//

import SwiftUI

/// 只负责编辑共享值类型，不在视图里请求网络或读取仓库分页。
struct RepoLicenseFilterSection: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    let options: [String]
    @Binding var selection: RepoLicenseFilter
    @State private var contentHeight: CGFloat = 30

    /// 标签含阴影，额外留白避免选中态在滚动边缘被截断；最多约四行。
    static let maximumContentHeight: CGFloat = 4 * 24 + 3 * 6 + 6

    /// 只限制视口，不减少真实选项；少量标签自然收缩，多量标签仍可在区内滚动查看。
    static func viewportHeight(for contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, 0), maximumContentHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("list.filter.license.title", businessIcon: .license, pointSize: 13 * interfaceScale.multiplier)
                .foregroundStyle(.secondary)
            ScrollView {
                TagChipFlowLayout(spacing: 6, constrainsItemWidth: true) {
                    RepoLicenseFilterChip(title: String.l10n("list.filter.license.all"), isSelected: !selection.isActive) {
                        selection = .all
                    }
                    ForEach(RepoLicenseFilter.options(options.map { Optional($0) }, including: selection), id: \.self) { key in
                        RepoLicenseFilterChip(
                            title: key == RepoLicenseFilter.unknownKey
                                ? String.l10n("list.filter.license.unknown") : RepoLicenseFilter.displayName(for: key),
                            isSelected: selection.selections.contains(key),
                            category: RepoLicenseCategory.category(for: key)
                        ) {
                            // 沿用既有绑定从当前集合切换，不引入第二份选择状态。
                            let selected = binding(for: key)
                            selected.wrappedValue.toggle()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(3)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .frame(height: Self.viewportHeight(for: contentHeight))
        }
    }

    /// 每次写入都从当前选择生成新值，快速连续勾选不会用旧捕获值覆盖前一项。
    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { selection.selections.contains(key) },
            set: { selected in
                var keys = selection.selections
                if selected { keys.insert(key) } else { keys.remove(key) }
                selection = RepoLicenseFilter(Array(keys))
            }
        )
    }
}
