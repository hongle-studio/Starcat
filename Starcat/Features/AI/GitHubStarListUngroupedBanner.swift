//
//  GitHubStarListUngroupedBanner.swift
//  Starcat
//
//  未分组视图顶部「开始 AI 分组整理」入口横幅。
//
//  模块职责：
//  - 在 RepoListView 选中「未分组」时，于中栏列表顶部展示与未分类横幅同构的入口。
//  - 空闲展示仓库总量，执行或待确认时展示当前任务；点击后由 HomeView 打开现有审核 sheet。
//
//  关键约束：
//  - 只负责入口外观与点击转发，不持有 sheet / 付费墙状态。
//  - 数量用侧栏同源的 ungrouped 总量，而不是当前列表 items.count，避免搜索过滤把入口语义缩小。
//  - 数量为 0 或未登录只禁止新开任务；已有任务仍可打开查看。
//

import SwiftUI

struct GitHubStarListUngroupedBanner: View {

    let ungroupedCount: Int
    let isLoggedIn: Bool
    let session: GitHubStarListAIGroupingSession
    let onStart: () -> Void

    var body: some View {
        AIOrganizationBanner(
            kind: .grouping, repositoryCount: ungroupedCount, state: .grouping(session), canStart: canStart,
            onStart: onStart,
            // 现有入口只打开工作区；prepareManualContext 会保留正在运行的人工会话。
            onShowPanel: onStart
        )
    }

    /// 没有可整理对象，或还没登录 GitHub，点下去也打不开有效分组流程。
    private var canStart: Bool {
        ungroupedCount > 0 && isLoggedIn
    }
}
