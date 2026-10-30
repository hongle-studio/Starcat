//
//  StarsSyncFollowUpCoordinatorTests.swift
//  StarcatTests
//
//  用可控异步门验证 Stars 旁路的触发、合并和账号隔离，不启动真实网络或操作桌面。
//

import Foundation
import Testing
@testable import Starcat

/// 注入的门故意不响应取消，验证迟到回调仍会被账号/代际检查挡住。
@MainActor
@Suite("Stars sync follow-up")
struct StarsSyncFollowUpCoordinatorTests {
    @Test("自动同步只读取快照，主动刷新才重试且每次只一轮")
    func onlyManualSyncRetries() async {
        var snapshots = 0
        var retries = 0
        let coordinator = StarsSyncFollowUpCoordinator(accountIDProvider: { 1 }, refreshGroups: { _ in
            snapshots += 1
            return true
        }, retryMemberships: { retries += 1 }, refreshDerivedData: { _ in })

        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: false)
        await waitUntil { !coordinator.isRunning }
        #expect(snapshots == 1)
        #expect(retries == 0)
        for _ in 0..<2 {
            coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: true)
            await waitUntil { !coordinator.isRunning }
        }
        #expect(snapshots == 3)
        #expect(retries == 2)
    }

    @Test("快照在途时手动刷新升级当前批次，不新增快照或重试队列")
    func manualRequestJoinsSnapshot() async {
        let snapshotsGate = FollowUpTestGate()
        let derivedGate = FollowUpTestGate()
        defer { snapshotsGate.open(); derivedGate.open() }
        var snapshots = 0
        var derived = 0
        var retries = 0
        let coordinator = StarsSyncFollowUpCoordinator(accountIDProvider: { 1 }, refreshGroups: { _ in
            snapshots += 1
            await snapshotsGate.wait()
            return true
        }, retryMemberships: { retries += 1 }, refreshDerivedData: { _ in
            derived += 1
            await derivedGate.wait()
        })
        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: false)
        await waitUntil { snapshots == 1 && derived == 1 }
        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: true)
        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: true)
        snapshotsGate.open()
        derivedGate.open()
        await waitUntil { !coordinator.isRunning }
        #expect(snapshots == 1)
        #expect(derived == 1)
        #expect(retries == 1)
    }

    @Test("授权重试已在途时重复点击不在结束后追加第二轮")
    func repeatedClicksDoNotQueueRetries() async {
        let gate = FollowUpTestGate()
        defer { gate.open() }
        var snapshots = 0
        var retries = 0
        let coordinator = StarsSyncFollowUpCoordinator(accountIDProvider: { 1 }, refreshGroups: { _ in
            snapshots += 1
            return true
        }, retryMemberships: {
            retries += 1
            await gate.wait()
        }, refreshDerivedData: { _ in })
        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: true)
        await waitUntil { retries == 1 }
        for _ in 0..<3 { coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: true) }
        gate.open()
        await waitUntil { !coordinator.isRunning }
        #expect(snapshots == 1)
        #expect(retries == 1)
    }

    @Test("慢索引不会阻塞下一次主动授权重试，快照失败不盲写")
    func derivedWorkDoesNotBlockRetries() async {
        let gate = FollowUpTestGate()
        defer { gate.open() }
        var snapshots = 0
        var retries = 0
        let coordinator = StarsSyncFollowUpCoordinator(accountIDProvider: { 1 }, refreshGroups: { _ in
            snapshots += 1
            return snapshots != 3
        }, retryMemberships: { retries += 1 }, refreshDerivedData: { _ in await gate.wait() })
        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: false)
        await waitUntil { snapshots == 1 && !coordinator.isProcessingGroups }
        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: true)
        await waitUntil { retries == 1 }
        #expect(coordinator.isRunning)
        await waitUntil { !coordinator.isProcessingGroups }
        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: true)
        await waitUntil { snapshots == 3 }
        gate.open()
        await waitUntil { !coordinator.isRunning }
        #expect(retries == 1)
    }

    @Test("账号切换等待旧工作退出，迟到结果不触发授权回写")
    func accountChangeRejectsLateCallbacks() async {
        let gate = FollowUpTestGate()
        defer { gate.open() }
        var accountID: Int64? = 1
        var snapshots = 0
        var retries = 0
        var resetFinished = false
        let coordinator = StarsSyncFollowUpCoordinator(accountIDProvider: { accountID }, refreshGroups: { _ in
            snapshots += 1
            await gate.wait()
            return true
        }, retryMemberships: { retries += 1 }, refreshDerivedData: { _ in })
        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: true)
        await waitUntil { snapshots == 1 }
        accountID = 2
        let reset = Task { await coordinator.resetForAccountChange(); resetFinished = true }
        await waitUntil { !coordinator.isRunning }
        #expect(!resetFinished)
        gate.open()
        await reset.value
        #expect(retries == 0)
        coordinator.schedule(userID: 1, login: "one", retryPendingMemberships: true)
        #expect(!coordinator.isRunning)
        coordinator.schedule(userID: 2, login: "two", retryPendingMemberships: true)
        await waitUntil { !coordinator.isRunning }
        #expect(retries == 1)
    }

    /// 等待业务边沿而非固定 sleep；失败时返回，defer 仍会放行门以免遗留后台 Task。
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { Issue.record("Timed out waiting for follow-up state"); return }
            await Task.yield()
        }
    }
}

/// 单测专用可重入门；每个 continuation 在 open 时且仅在此处恢复一次。
@MainActor
private final class FollowUpTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters = []
        for waiter in current { waiter.resume() }
    }
}
