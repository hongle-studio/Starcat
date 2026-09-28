//
//  ExternalStarInbox.swift
//  Starcat
//
//  前台探测 GitHub `/user/starred` 第一页，找出本地还没有的外部新增 star，
//  攒进内存队列供中栏胶囊展示。点击后再走现有 SyncManager 增量同步。
//
//  关键约束：
//  - 探测不得写入 repos / lastSyncAt / 同步用的 starsETag。探测 ETag 只活在内存里，
//    否则点胶囊时 SyncManager 会 304 早退，新仓库进不来。
//  - 队列跨探测轮次累加，整批插到最前，避免逐条 prepend 把同一轮顺序反转。
//  - TestEnvironment 只挡住 15 秒循环，不挡住 poll()，单测才能驱动探测。
//  - 本地还没有 lastSyncAt 时不探测，避免首次同步前把整页当成新 star。
//

import AppKit
import Foundation
import Observation

/// 胶囊头像槽：最多 3 个真实头像，超出部分收成 `+N`。
enum ExternalStarInboxPresentation {
    enum Slot: Equatable {
        case avatar(repoID: Int64, ownerLogin: String, avatarURL: String?)
        case overflow(Int)
    }

    static func slots(
        from items: [ExternalStarInbox.Item],
        maxAvatars: Int = 3
    ) -> [Slot] {
        let overflow = items.count - maxAvatars
        let avatars = items.prefix(maxAvatars).map {
            Slot.avatar(repoID: $0.repoID, ownerLogin: $0.ownerLogin, avatarURL: $0.avatarURL)
        }
        if overflow > 0 {
            return avatars + [.overflow(overflow)]
        }
        return Array(avatars)
    }
}

/// 外部新增星标的前台收件箱。先提示，点了才同步。
@MainActor
@Observable
final class ExternalStarInbox {

    /// 待同步队列项。只为胶囊渲染和去重服务，不入库。
    struct Item: Equatable, Identifiable, Sendable {
        var id: Int64 { repoID }
        let repoID: Int64
        let ownerLogin: String
        let avatarURL: String?
        let starredAt: String
    }

    /// 前台探测间隔。
    static let pollInterval: TimeInterval = 15

    /// 最新在前的待同步队列。
    private(set) var pending: [Item] = []

    /// 15 秒循环是否在跑。测试 host 必须保持 false。
    private(set) var isLoopRunning = false

    @ObservationIgnored
    private let apiClient: any GitHubAPIClientProtocol
    @ObservationIgnored
    private let repository: any RepoRepositoryProtocol
    @ObservationIgnored
    private let syncManager: SyncManager
    @ObservationIgnored
    private let userIDProvider: () -> Int64?
    @ObservationIgnored
    private let isAppActive: () -> Bool
    /// 探测专用 ETag，禁止写进同步表。
    @ObservationIgnored
    private var probeETag: String?
    /// 点击收起后作废仍在途的探测结果，避免胶囊被旧响应重新填回来。
    @ObservationIgnored
    private var dismissGeneration: UInt64 = 0
    @ObservationIgnored
    private var loop: Task<Void, Never>?
    @ObservationIgnored
    private var becomeActiveObserver: NSObjectProtocol?

    init(
        apiClient: any GitHubAPIClientProtocol,
        repository: any RepoRepositoryProtocol,
        syncManager: SyncManager,
        userIDProvider: @escaping () -> Int64?,
        isAppActive: @escaping () -> Bool = { NSApp.isActive }
    ) {
        self.apiClient = apiClient
        self.repository = repository
        self.syncManager = syncManager
        self.userIDProvider = userIDProvider
        self.isAppActive = isAppActive
    }

    /// 立即探测一次。循环入口与单测都走这里。
    func poll() async {
        guard isAppActive() else { return }
        guard let userID = userIDProvider() else { return }
        guard !syncManager.isSyncing else { return }
        if case .rateLimited = syncManager.state { return }

        let lastSyncAt = (try? await repository.fetchLastSyncAt(userID: userID)) ?? nil
        guard lastSyncAt != nil else { return }
        let generation = dismissGeneration

        let response: APIResponse<[StarredRepoDTO]>
        do {
            response = try await apiClient.starredRepos(
                page: 1,
                perPage: 100,
                ifNoneMatch: probeETag
            )
        } catch NetworkError.notModified {
            return
        } catch {
            AppLog.sync.error(
                "External star probe failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        guard generation == dismissGeneration else { return }

        if let etag = response.etag, !etag.isEmpty {
            probeETag = etag
        }

        let localIDs = Set((try? await repository.fetchStarredRepoIDs()) ?? [])
        let pendingIDs = Set(pending.map(\.repoID))
        let newItems = response.value.compactMap { dto -> Item? in
            let id = dto.repo.id
            guard !localIDs.contains(id), !pendingIDs.contains(id) else { return nil }
            return Item(
                repoID: id,
                ownerLogin: dto.repo.owner.login,
                avatarURL: dto.repo.owner.avatarUrl,
                starredAt: dto.starredAt
            )
        }
        if !newItems.isEmpty {
            pending = newItems + pending
        }
    }

    /// 点胶囊：立刻收起提示，再走现有增量同步。
    ///
    /// 产品要求点击后马上消失，不能等同步成功。探测 ETag 一并丢掉，
    /// 这样同步失败时下一轮 poll 还能重新发现仍未入库的仓库。
    func apply() {
        dismissPending()
        guard let userID = userIDProvider() else { return }
        syncManager.performFullSync(userID: userID)
    }

    func dismissPending() {
        pending = []
        probeETag = nil
        dismissGeneration &+= 1
    }

    /// 顶栏刷新等其它同步入口：同步一开始就把胶囊收掉。
    func handleSyncStarted() {
        dismissPending()
    }

    /// 同步成功后再按本地 ID 清一次，防止其它入口漏掉 dismiss。
    func handleSyncCompleted() async {
        guard case .completed = syncManager.state else { return }
        let local = Set((try? await repository.fetchStarredRepoIDs()) ?? [])
        pending.removeAll { local.contains($0.repoID) }
    }

    func resetForAccountChange() {
        pending = []
        probeETag = nil
        dismissGeneration &+= 1
    }

    func start() {
        guard !TestEnvironment.isRunning else { return }
        guard loop == nil else { return }
        isLoopRunning = true
        loop = Task { [weak self] in
            await self?.poll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                await self?.poll()
            }
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isLoopRunning = false
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
            self.becomeActiveObserver = nil
        }
    }
}
