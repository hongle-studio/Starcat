//
//  StarsSyncFollowUpCoordinator.swift
//  Starcat
//
//  Stars 已完成后的旁路工作：分组与衍生索引独立运行，不持有主同步的刷新状态。
//  仅合并在途工作，不建立永久队列；账号切换必须取消并等待旧工作退出后才能切库。
//

import Foundation

/// 分组快照、主动授权重试与 RAG/共享快照的任务所有者。
/// 两条 lane 相互独立，慢索引不能拖住用户刚发起的组织授权重试。
@MainActor
final class StarsSyncFollowUpCoordinator {
    private let accountIDProvider: () -> Int64?
    private let refreshGroups: (String) async -> Bool
    private let retryMemberships: () async -> Void
    private let refreshDerivedData: (Int64) async -> Void
    private var groupsTask: Task<Void, Never>?
    private var derivedTask: Task<Void, Never>?
    private var retryRequested = false
    private var retryStarted = false
    private var generation: UInt64 = 0
    private var isResetting = false

    var isProcessingGroups: Bool { groupsTask != nil }
    var isRunning: Bool { isProcessingGroups || derivedTask != nil }

    init(
        accountIDProvider: @escaping () -> Int64?,
        refreshGroups: @escaping (String) async -> Bool,
        retryMemberships: @escaping () async -> Void,
        refreshDerivedData: @escaping (Int64) async -> Void
    ) {
        self.accountIDProvider = accountIDProvider
        self.refreshGroups = refreshGroups
        self.retryMemberships = retryMemberships
        self.refreshDerivedData = refreshDerivedData
    }

    /// 普通同步只读分组；手动刷新允许当前批次在快照就绪后追加一次授权重试。
    /// 重试已开始时重复点击不追加第二轮；下一次主动刷新仍可重新验证新授权。
    func schedule(userID: Int64, login: String, retryPendingMemberships: Bool) {
        guard !isResetting, accountIDProvider() == userID else { return }
        let scope = generation
        if !retryStarted { retryRequested = retryRequested || retryPendingMemberships }
        if groupsTask == nil {
            groupsTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if generation == scope {
                        groupsTask = nil
                        retryRequested = false
                        retryStarted = false
                    }
                }
                guard isCurrent(userID: userID, generation: scope) else { return }
                let refreshed = await refreshGroups(login)
                guard refreshed, isCurrent(userID: userID, generation: scope) else { return }
                if retryRequested {
                    retryStarted = true
                    await retryMemberships()
                }
            }
        }
        if derivedTask == nil {
            derivedTask = Task { [weak self] in
                guard let self else { return }
                defer { if generation == scope { derivedTask = nil } }
                guard isCurrent(userID: userID, generation: scope) else { return }
                await refreshDerivedData(userID)
            }
        }
    }

    /// 取消是协作式的：必须 await 句柄，确保旧数据库读写已退出，不能只清空 Task 引用。
    func resetForAccountChange() async {
        isResetting = true
        generation &+= 1
        let oldGroups = groupsTask
        let oldDerived = derivedTask
        groupsTask = nil
        derivedTask = nil
        retryRequested = false
        retryStarted = false
        oldGroups?.cancel()
        oldDerived?.cancel()
        await oldGroups?.value
        await oldDerived?.value
        isResetting = false
    }

    private func isCurrent(userID: Int64, generation scope: UInt64) -> Bool {
        !Task.isCancelled && generation == scope && accountIDProvider() == userID
    }
}
