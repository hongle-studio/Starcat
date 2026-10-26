//
//  AdaptiveToolbarStatusTextTests.swift
//  StarcatTests
//
//  验证辅助描述的退让顺序与刷新提示契约；不读取或操作用户界面。
//

import Testing
@testable import Starcat

/// 按钮保持默认优先级，描述其次，留白最后；重要提示不得变成可隐藏描述。
@MainActor
struct AdaptiveToolbarStatusTextTests {
    @Test func optionalDescriptionYieldsToControlsBeforeSpacer() {
        let description = AdaptiveToolbarStatusText(text: "刚刚")
        #expect(description.priority < 0)
        #expect(AdaptiveToolbarStatusText.spacerPriority < description.priority)
    }

    @Test func requiredWarningKeepsControlPriority() {
        let warning = AdaptiveToolbarStatusText(text: "数据已陈旧", isRequired: true)
        #expect(warning.priority == 0)
        #expect(warning.priority > AdaptiveToolbarStatusText.spacerPriority)
    }

    @Test(arguments: [nil, "", " \n "] as [String?])
    func absentDescriptionDoesNotAlterAction(status: String?) {
        #expect(AdaptiveToolbarStatusText.refreshTooltip(action: "刷新", status: status) == "刷新")
    }

    /// 完整说明不截断、不改写；同一格式同时保留中英文和多行辅助文案。
    @Test(arguments: ["刚刚", "上次刷新于 2026年10月20日 18:30", "Last refreshed three hours ago", "缓存时间\n2026-10-20 18:30"])
    func tooltipPreservesFullDescription(status: String) {
        let tooltip = AdaptiveToolbarStatusText.refreshTooltip(action: "刷新", status: status)
        #expect(tooltip == "刷新\n\(status)")
    }
}
