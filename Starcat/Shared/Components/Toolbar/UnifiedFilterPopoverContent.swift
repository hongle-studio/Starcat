//
//  UnifiedFilterPopoverContent.swift
//  Starcat
//
//  筛选浮层的稳定布局；只负责展示，关闭浮层与重置行为仍由调用方执行。
//

import SwiftUI

/// 底部重置区始终保留尺寸，避免首次筛选和清空最后一项时整个浮层重新定位。
struct UnifiedFilterPopoverContent<Content: View>: View {
    let isAnyFilterActive: Bool
    let onReset: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)

            if let onReset {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                        .padding(.horizontal, 12)
                    Button(role: .destructive, action: onReset) {
                        Label("list.filter.reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                // 隐藏时仅占位：不能被点击、键盘聚焦或辅助功能读取。
                .opacity(isAnyFilterActive ? 1 : 0)
                .disabled(!isAnyFilterActive)
                .allowsHitTesting(isAnyFilterActive)
                .accessibilityHidden(!isAnyFilterActive)
            }
        }
        .frame(width: 260, alignment: .leading)
    }
}
