//
//  AmbientGridMetrics.swift
//  Starcat
//
//  五行无缝满铺网格的纯几何。App Ambient 与系统屏保共用，避免两套行列算法漂移。
//

import CoreGraphics
import Foundation

/// 从实际 content geometry 推导正方形 tile 边长、列数和裁切宽度。
struct AmbientGridMetrics: Equatable, Sendable {
    static let rowCount = 5

    let tilePointSize: Double
    let columnCount: Int
    let contentWidth: Double
    let contentHeight: Double
    let viewportWidth: Double
    let viewportHeight: Double
    let isUsable: Bool

    init(size: CGSize) {
        let width = max(1, Double(size.width))
        let height = max(1, Double(size.height))
        let tile = max(1, height / Double(Self.rowCount))
        // 多取完整一列并居中裁切，而不是缩小 tile 或留下左右黑边。
        let columns = max(1, Int(ceil(width / tile)))

        tilePointSize = tile
        columnCount = columns
        contentWidth = Double(columns) * tile
        contentHeight = Double(Self.rowCount) * tile
        viewportWidth = width
        viewportHeight = height
        // AppKit 全屏切换期间可能短暂送出 0×0 / 极小 content size；这些不是可展示布局。
        isUsable = size.width >= 100 && size.height >= 200
    }

    /// 系统设置屏保缩略图经常只有一百多 pt 高。App Ambient 的 200pt 门槛不能套过来，
    /// 否则预览会永远停在空态图标。
    var canConfigureScreensaver: Bool {
        viewportWidth >= 40 && viewportHeight >= 40
    }

    func layout(displayScale: Double) -> AmbientGridLayout {
        AmbientGridLayout(
            config: AmbientGridConfig(rowCount: Self.rowCount, columnCount: columnCount),
            tilePointSize: tilePointSize,
            displayScale: displayScale
        )
    }
}
