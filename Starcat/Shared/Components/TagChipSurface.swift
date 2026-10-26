//
//  TagChipSurface.swift
//  Starcat
//
//  左侧标签墙与许可证筛选共用的胶囊外观，不接管点击、计数或筛选状态。
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// 保留标签墙既有的圆角、留白、底色与描边，避免两处分别维护后再次产生样式差异。
struct TagChipSurface: ViewModifier {
    static let cornerRadius: CGFloat = 6
    let color: Color
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.18)))
            }
            // 选中态沿用左侧标签的实色底，需按亮度使用黑/白字；未选中仍为系统主文字色。
            .foregroundStyle(isSelected ? AnyShapeStyle(Self.selectedForeground(for: color)) : AnyShapeStyle(.primary))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(color.opacity(isSelected ? 0.9 : 0.35), lineWidth: isSelected ? 1 : 0.5)
            }
            .shadow(color: color.opacity(isSelected ? 0.35 : 0), radius: 2, y: 1)
    }

    /// 沿用原标签墙的 sRGB 亮度阈值，确保浅色标签选中后仍有可读的文字对比度。
    static func selectedForeground(for color: Color) -> Color {
        #if canImport(AppKit)
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * Double(rgb.redComponent)
            + 0.7152 * Double(rgb.greenComponent)
            + 0.0722 * Double(rgb.blueComponent)
        return luminance > 0.6 ? .black : .white
        #else
        return .white
        #endif
    }
}
