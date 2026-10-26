//
//  AIOrganizationBannerState.swift
//  Starcat
//
//  两种 AI 整理入口的只读状态投影；不把“分析完成”当成“确认应用完成”。
//

import Foundation

/// 横幅只持有展示值，后台任务及可恢复结果仍由原 Session / Service 拥有。
enum AIOrganizationBannerState: Equatable {
    case idle
    case preparing
    case analyzing(processed: Int, total: Int)
    case applying(processed: Int, total: Int)
    case paused(processed: Int, total: Int)
    case review(count: Int)
    case failed(count: Int)

    var actionKey: String {
        switch self {
        case .idle: "batchAI.banner.start"
        case .preparing, .analyzing, .applying: "batchAI.banner.viewProgress"
        case .paused: "aiOrganization.banner.viewTask"
        case .review, .failed: "aiOrganization.banner.viewResults"
        }
    }

    var statusIcon: String {
        switch self {
        case .idle, .preparing, .analyzing: "sparkles"
        case .applying: "gearshape.2"
        case .paused: "pause.circle"
        case .review: "checklist"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// 应用锁先判断；刷新远端 membership 时尚无分母，显示准备说明而不是旧批次的 100%。
    @MainActor
    static func grouping(_ session: GitHubStarListAIGroupingSession) -> Self {
        guard session.mode == .manual else { return .idle }
        if session.isApplying {
            return .applying(processed: session.applicationProgress?.processedRepositoryCount ?? 0,
                             total: session.applicationProgress?.totalRepositoryCount ?? 0)
        }
        if session.isStartingManual { return .preparing }
        if session.isPaused { return .paused(processed: session.analyzedCount, total: session.analysisTotalCount) }
        if session.isRunning { return .analyzing(processed: session.analyzedCount, total: session.analysisTotalCount) }

        // 只做一次轻量扫描，不为横幅构造、排序整个审核列表，也不计入用户已忽略的项目。
        var pending = 0
        var failures = 0
        var unfinished = false
        for job in session.jobs where !session.ignoredRepoIDs.contains(job.id) {
            switch job.applyState {
            case .ignored, .applied: continue
            case .failed: failures += 1; continue
            case .applying: return .applying(processed: 0, total: 0)
            case .idle: break
            }
            switch job.status {
            case .failed: failures += 1
            case .queued, .analyzing, .stopped: unfinished = true
            case .completed:
                let current = session.existingListIDsByRepo[job.id] ?? []
                if job.suggestions.contains(where: { !current.contains($0.listId) })
                    || !(session.selectedListIDsByRepo[job.id] ?? []).subtracting(current).isEmpty {
                    pending += 1
                }
            }
        }
        if unfinished { return .paused(processed: session.analyzedCount, total: session.analysisTotalCount) }
        if failures > 0 { return .failed(count: failures) }
        return pending > 0 ? .review(count: pending) : .idle
    }

    /// 标签写入与 AI 分析是独立阶段；isFinished 只能表示分析终态，不能决定是否展示开始按钮。
    @MainActor
    static func tags(_ service: BatchAIQueueService) -> Self {
        if service.isApplyingSuggestedTags {
            return .applying(processed: service.tagApplicationProgress?.processedRepositoryCount ?? 0,
                             total: service.tagApplicationProgress?.totalRepositoryCount ?? 0)
        }
        if service.isPaused { return .paused(processed: service.finishedCount, total: service.totalCount) }
        if service.isRunning { return .analyzing(processed: service.finishedCount, total: service.totalCount) }
        var pending = 0
        var failures = 0
        var unfinished = false
        for job in service.jobs {
            if case .failed = job.tagReviewState { failures += 1; continue }
            if job.status == .failed { failures += 1; continue }
            if job.status == .queued || job.status == .processing { unfinished = true }
            if case .pending = job.tagReviewState { pending += 1 }
        }
        if unfinished { return .paused(processed: service.finishedCount, total: service.totalCount) }
        if failures > 0 { return .failed(count: failures) }
        if service.tagExpansionError != nil { return .failed(count: 0) }
        if pending > 0 { return .review(count: pending) }
        // 批次词表仍需确认时同样重开当前工作区，但不把词表项数伪装成仓库数。
        if service.hasUnresolvedManualWork { return .review(count: 0) }
        return .idle
    }
}
