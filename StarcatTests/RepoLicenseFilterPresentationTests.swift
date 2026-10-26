//
//  RepoLicenseFilterPresentationTests.swift
//  StarcatTests
//
//  许可证标签墙的离屏布局契约；只测量 SwiftUI 视图，不启动窗口或操作用户的桌面。
//

import SwiftUI
import Testing
@testable import Starcat

/// 与左侧标签既有测试采用相同的离屏测量方式，覆盖紧凑换行、长名称和选中态稳定性。
@MainActor
@Suite("License filter chip presentation")
struct RepoLicenseFilterPresentationTests {
    /// 显式给定可用宽度，模拟全局筛选浮层内的测量提案，而不是读取屏幕尺寸。
    private func size<Content: View>(of content: Content, width: CGFloat) throws -> CGSize {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.nsImage).size
    }

    @Test("同一行容纳多个短标签，不再一项占一行")
    func shortChipsShareOneRow() throws {
        let chip = RepoLicenseFilterChip(title: "MIT", isSelected: false, action: {})
        let single = try size(of: chip, width: 236)
        let flow = try size(of: TagChipFlowLayout(constrainsItemWidth: true) {
            chip
            RepoLicenseFilterChip(title: "BSD", isSelected: false, action: {})
        }, width: 236)
        #expect(flow.height == single.height)
    }

    @Test("长许可证名称限制在可用宽度，选中不会改变胶囊尺寸", arguments: [140.0, 236.0])
    func longNameFitsAvailableWidth(width: Double) throws {
        let title = String(repeating: "LicenseRef-Custom-", count: 12)
        let normal = try size(of: RepoLicenseFilterChip(title: title, isSelected: false, action: {}), width: width)
        let selected = try size(of: RepoLicenseFilterChip(title: title, isSelected: true, action: {}), width: width)
        let singleLine = try size(of: RepoLicenseFilterChip(title: "MIT", isSelected: false, action: {}), width: width)
        #expect(normal.width <= width)
        #expect(normal.height == singleLine.height)
        #expect(selected == normal)
    }

    @Test("换行高度与行间距一致")
    func wrappingKeepsTagWallSpacing() throws {
        let flow = try size(of: TagChipFlowLayout(spacing: 6, constrainsItemWidth: true) {
            ForEach(0..<3) { _ in Color.clear.frame(width: 80, height: 24) }
        }, width: 200)
        // 离屏 NSImage 的点/像素换算可能产生浮点尾差，验证间距时保留远小于一像素的容差。
        let expectedHeight: CGFloat = 24 * 2 + 6
        #expect(abs(flow.height - expectedHeight) < 0.01)
    }

    @Test("少量内容自然收缩，超过约四行只限制视口")
    func viewportAdaptsToContent() {
        #expect(RepoLicenseFilterSection.viewportHeight(for: 30) == 30)
        #expect(RepoLicenseFilterSection.viewportHeight(for: 72) == 72)
        #expect(RepoLicenseFilterSection.viewportHeight(for: 600) == RepoLicenseFilterSection.maximumContentHeight)
    }

    @Test("分类配色和选中态均不改变胶囊尺寸", arguments: RepoLicenseCategory.allCases, [ColorScheme.light, .dark])
    func categoryColorsKeepChipSize(category: RepoLicenseCategory, colorScheme: ColorScheme) throws {
        let normal = try size(of: RepoLicenseFilterChip(title: "MIT", isSelected: false, category: category, action: {})
            .environment(\.colorScheme, colorScheme), width: 236)
        let selected = try size(of: RepoLicenseFilterChip(title: "MIT", isSelected: true, category: category, action: {})
            .environment(\.colorScheme, colorScheme), width: 236)
        let all = try size(of: RepoLicenseFilterChip(title: "MIT", isSelected: false, action: {})
            .environment(\.colorScheme, colorScheme), width: 236)
        #expect(normal == selected)
        #expect(normal == all)
    }

    @Test("首次选中与清空最后一项不增减浮层高度", arguments: [ColorScheme.light, .dark])
    func resetFooterReservesStableSpace(colorScheme: ColorScheme) throws {
        let active = try size(of: UnifiedFilterPopoverContent(isAnyFilterActive: true, onReset: {}) {
            Text(verbatim: "Filter content")
        }.environment(\.colorScheme, colorScheme), width: 260)
        let inactive = try size(of: UnifiedFilterPopoverContent(isAnyFilterActive: false, onReset: {}) {
            Text(verbatim: "Filter content")
        }.environment(\.colorScheme, colorScheme), width: 260)
        let noReset = try size(of: UnifiedFilterPopoverContent(isAnyFilterActive: false, onReset: nil) {
            Text(verbatim: "Filter content")
        }.environment(\.colorScheme, colorScheme), width: 260)
        #expect(active == inactive)
        #expect(noReset.height < inactive.height)
    }
}
