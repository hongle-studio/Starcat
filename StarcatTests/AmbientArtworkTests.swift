//
//  AmbientArtworkTests.swift
//  StarcatTests
//
//  校验屏保占位色板，以及五行网格在桌面和系统设置缩略图里的几何。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Ambient Artwork")
struct AmbientArtworkTests {
    @Test("占位 monogram 与色板索引跨调用稳定")
    func placeholderIsStable() {
        let first = AmbientArtworkStyle.paletteIndex(for: "owner:apple")
        let second = AmbientArtworkStyle.paletteIndex(for: "owner:apple")

        #expect(first == second)
        #expect((0..<AmbientArtworkStyle.paletteCount).contains(first))
        #expect(AmbientArtworkStyle.monogram(from: "  apple") == "A")
        #expect(AmbientArtworkStyle.monogram(from: "   ") == nil)
    }

    @Test("五行布局零间距铺满高度并横向超宽裁切")
    func gridMetricsFillAndCropAvailableGeometry() {
        let desktop = AmbientGridMetrics(size: CGSize(width: 1_920, height: 1_080))
        let narrow = AmbientGridMetrics(size: CGSize(width: 200, height: 1_000))
        let transient = AmbientGridMetrics(size: .zero)

        #expect(desktop.tilePointSize == 216)
        #expect(desktop.columnCount == 9)
        #expect(desktop.contentWidth == 1_944)
        #expect(desktop.contentWidth >= desktop.viewportWidth)
        #expect(desktop.contentHeight == desktop.viewportHeight)
        #expect(narrow.columnCount == 1)
        #expect(narrow.contentWidth == narrow.viewportWidth)
        #expect(narrow.contentHeight == narrow.viewportHeight)
        #expect(!transient.isUsable)
        #expect(!transient.canConfigureScreensaver)
    }

    @Test("系统设置屏保缩略图高度经常不足 200pt，仍要能配置网格")
    func screensaverPreviewAcceptsSettingsThumbnail() {
        let thumbnail = AmbientGridMetrics(size: CGSize(width: 280, height: 160))
        #expect(!thumbnail.isUsable)
        #expect(thumbnail.canConfigureScreensaver)
        #expect(thumbnail.columnCount >= 1)
        #expect(thumbnail.tilePointSize == 32)
    }
}
