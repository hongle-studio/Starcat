//
//  BatchAIUntaggedBanner.swift
//  Starcat
//
//  HOM-52 - Untagged 视图顶部"开始批量 AI 整理"入口横幅。
//
//  模块职责：
//  - 在 RepoListView 的 Untagged 视图顶部展示一个轻量横幅。
//  - 显示当前未分类仓库数 + 启动按钮 / 查看进度按钮。
//  - 与队列服务状态联动：进行中 / 已完成时按钮文案与图标变化。
//
//  关键约束：
//  - 仅在 selection == .untagged 时显示，避免污染其它视图。
//  - 队列已在跑时按钮变为"查看进度"，点击直接打开 panel（不要求重新选择 options）。
//

import SwiftUI

struct BatchAIUntaggedBanner: View {

    let untaggedCount: Int
    @Bindable var service: BatchAIQueueService

    let onStart: () -> Void
    let onShowPanel: () -> Void

    var body: some View {
        AIOrganizationBanner(
            kind: .tags, repositoryCount: untaggedCount, state: .tags(service), canStart: untaggedCount > 0,
            onStart: onStart, onShowPanel: onShowPanel
        )
    }
}
