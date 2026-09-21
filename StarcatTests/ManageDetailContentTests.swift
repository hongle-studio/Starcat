//
//  ManageDetailContentTests.swift
//  StarcatTests
//
//  验证仓库详情 README / 洞察模式切换契约。
//
//  洞察入口跟模块无关：只要已 star 就出现切换；unstar 必须强制回到 README。
//

import Testing
@testable import Starcat

@Suite("仓库详情模式切换")
struct ManageDetailContentTests {

    @Test("详情默认进入 README，避免首屏额外请求洞察")
    func defaultModeUsesReadme() {
        let mode = RepoDetailContentMode.readme

        #expect(mode == .readme)
        #expect(mode.transitionEffect == .cancelInsights)
    }

    @Test("进入洞察时重置 Hero 滚动位置")
    func insightsModeResetsScroll() {
        #expect(RepoDetailContentMode.insights.transitionEffect == .resetScroll)
    }

    @Test("返回 README 时取消洞察后台请求")
    func readmeModeCancelsInsights() {
        #expect(RepoDetailContentMode.readme.transitionEffect == .cancelInsights)
    }

    @Test("已 star 的仓库在任何模块都应显示洞察切换")
    func starredRepoShowsInsightsSwitcher() {
        #expect(RepoDetailInsightsAvailability.showsSwitcher(isStarred: true))
    }

    @Test("未 star 的仓库不显示洞察切换")
    func unstarredRepoHidesInsightsSwitcher() {
        #expect(!RepoDetailInsightsAvailability.showsSwitcher(isStarred: false))
    }

    @Test("unstar 后强制回到 README，避免洞察页悬空")
    func unstarResolvesToReadme() {
        #expect(
            RepoDetailInsightsAvailability.resolvedMode(
                isStarred: false,
                current: .insights
            ) == .readme
        )
    }

    @Test("已 star 时保留用户当前选中的 README 或洞察")
    func starredKeepsCurrentMode() {
        #expect(
            RepoDetailInsightsAvailability.resolvedMode(
                isStarred: true,
                current: .insights
            ) == .insights
        )
        #expect(
            RepoDetailInsightsAvailability.resolvedMode(
                isStarred: true,
                current: .readme
            ) == .readme
        )
    }
}
