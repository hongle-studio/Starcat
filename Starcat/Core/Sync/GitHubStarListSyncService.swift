//
//  GitHubStarListSyncService.swift
//  Starcat
//
//  GitHub Stars List 同步与用户写入操作协调层。
//
//  设计约束：
//  - GitHub 是远端真源；正常写入先 mutation 成功再更新远端缓存。
//  - 只有明确命中组织 OAuth 限制时才降级为本地覆盖；网络、鉴权和其它错误仍然抛出。
//  - `updateUserListsForItem` 是替换式写入，所以 add/remove/批量新增都先读取本地完整
//    membership，计算目标集合后一次提交。
//  - 本服务只处理 GitHub List，不处理 Starcat Tags / Smart Collections。
//

import Foundation
import GRDB

/// 批量更新 GitHub Stars List membership 的结果摘要。
///
/// 单条失败不会中断后续仓库；已经处于目标状态的仓库计入 skipped，避免重复 mutation。
struct GitHubStarListBatchMembershipSummary: Equatable, Sendable {
    let total: Int
    let succeeded: Int
    let skipped: Int
    let failed: Int
    /// 已计入 succeeded，但当前只在 Starcat 内生效的数量。
    let savedLocally: Int

    init(total: Int, succeeded: Int, skipped: Int, failed: Int, savedLocally: Int = 0) {
        self.total = total
        self.succeeded = succeeded
        self.skipped = skipped
        self.failed = failed
        self.savedLocally = savedLocally
    }
}

/// 一次 membership 写入最终落在 GitHub，还是暂存在 Starcat 本地。
enum GitHubStarListMembershipWriteLocation: Equatable, Sendable {
    case github
    case local
}

/// AI 批量新增既要知道实际新增了哪些 Lists，也要向审核页暴露写入位置。
struct GitHubStarListMembershipWriteResult: Equatable, Sendable {
    let changedListIDs: Set<String>
    let location: GitHubStarListMembershipWriteLocation
}

/// 待回写本地覆盖的一次重试汇总。
struct GitHubStarListPendingMembershipSyncSummary: Equatable, Sendable {
    let total: Int
    let synced: Int
    let stillPending: Int
    let failed: Int
}

/// 同步服务只依赖 GitHub Lists API，避免测试批量调度时必须经过 URLSession 的串行 Stub 队列。
protocol GitHubStarListAPIClientProtocol: AnyObject, Sendable {
    func starLists(login: String) async throws -> GitHubStarListRemoteSnapshot
    func createUserList(
        name: String,
        description: String?,
        isPrivate: Bool
    ) async throws -> GitHubStarListRemoteRecord
    func updateUserList(
        id: String,
        name: String,
        description: String?,
        isPrivate: Bool
    ) async throws -> GitHubStarListRemoteRecord
    func deleteUserList(id: String) async throws
    func updateUserListsForRepository(
        owner: String,
        name: String,
        listIds: [String]
    ) async throws -> [GitHubStarListRemoteRecord]
}

extension GitHubAPIClient: GitHubStarListAPIClientProtocol {}

@MainActor
@Observable
final class GitHubStarListSyncService {

    /// GitHub mutation 保持小规模并发，缩短批量等待，同时避免把大量请求瞬间压到 GitHub。
    private static let batchMembershipConcurrency = 3

    private let apiClient: any GitHubStarListAPIClientProtocol
    private let repository: any GitHubStarListRepositoryProtocol

    /// 同一轮操作里，一个 owner 已确认受限后，后续仓库直接本地落盘，避免重复制造必败请求。
    /// 每次完整同步或用户显式重试都会清空，让新授权可以被及时探测。
    private var locallyRestrictedOwners: Set<String> = []

    private(set) var isSyncing = false
    private(set) var lastErrorMessage: String?

    init(
        apiClient: any GitHubStarListAPIClientProtocol,
        repository: any GitHubStarListRepositoryProtocol
    ) {
        self.apiClient = apiClient
        self.repository = repository
    }

    /// 从 GitHub 拉取完整 list 快照并覆盖本地缓存。
    func sync(login: String) async {
        guard !login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let snapshot = try await apiClient.starLists(login: login)
            try await repository.replaceRemoteSnapshot(
                lists: snapshot.lists,
                memberships: snapshot.memberships,
                syncedAt: Date()
            )
            locallyRestrictedOwners.removeAll()
            let pendingSummary = await reconcilePendingLocalMemberships()
            if pendingSummary.failed > 0 {
                AppLog.network.warning("GitHub star list local override reconciliation kept \(pendingSummary.failed, privacy: .public) non-restriction failures pending")
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.network.error("GitHub star lists sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func createList(
        name: String,
        description: String?,
        isPrivate: Bool,
        colorHex: String?,
        aiInstruction: String = "",
        autoApplyEnabled: Bool = false
    ) async throws -> GitHubStarList {
        let remote = try await apiClient.createUserList(
            name: name,
            description: description,
            isPrivate: isPrivate
        )
        try await repository.upsertList(remote, colorHex: colorHex, syncedAt: Date())
        try await saveAIRule(
            listID: remote.id,
            instruction: aiInstruction,
            autoApplyEnabled: autoApplyEnabled
        )
        return try await requireList(id: remote.id)
    }

    @discardableResult
    func updateList(
        id: String,
        name: String,
        description: String?,
        isPrivate: Bool,
        colorHex: String?,
        aiInstruction: String = "",
        autoApplyEnabled: Bool = false
    ) async throws -> GitHubStarList {
        let existing = try await repository.findList(id: id)
        var remote = try await apiClient.updateUserList(
            id: id,
            name: name,
            description: description,
            isPrivate: isPrivate
        )
        // GitHub mutation 返回 list 本身，但不表达它在 viewer.lists connection 里的位置；
        // 编辑本地缓存时沿用已有 position，避免某个 list 被编辑后跳到首位。
        remote.position = existing?.position ?? remote.position
        try await repository.upsertList(remote, colorHex: colorHex, syncedAt: Date())
        try await saveAIRule(
            listID: id,
            instruction: aiInstruction,
            autoApplyEnabled: autoApplyEnabled
        )
        return try await requireList(id: id)
    }

    func deleteList(id: String) async throws {
        try await apiClient.deleteUserList(id: id)
        try await repository.deleteList(id: id)
    }

    func aiRule(forList listID: String) async throws -> GitHubStarListAIRule? {
        try await repository.findAIRule(listId: listID)
    }

    func allAIRules() async throws -> [GitHubStarListAIRule] {
        try await repository.fetchAllAIRules()
    }

    /// 开始页只用分组计数，避免为概览去解码全部 membership 行。
    func repoCountsByList() async throws -> [String: Int] {
        try await repository.repoCountsByList()
    }

    func ungroupedRepoCount() async throws -> Int {
        try await repository.ungroupedRepoCount()
    }

    /// 手动/自动 AI 整理在启动时读取完整快照，避免依赖当前 Sidebar 是否已经展开。
    func allLists() async throws -> [GitHubStarList] {
        try await repository.fetchAllLists()
    }

    func allListAssignments() async throws -> [Int64: [GitHubStarList]] {
        try await repository.fetchAllListAssignments()
    }

    func allAIAutoIgnoredRepos() async throws -> [GitHubStarListAIAutoIgnoredRepo] {
        try await repository.fetchAIAutoIgnoredRepos()
    }

    func markAIAutoIgnored(
        repoID: Int64,
        reason: GitHubStarListAIAutoIgnoreReason
    ) async throws {
        try await repository.upsertAIAutoIgnoredRepo(GitHubStarListAIAutoIgnoredRepo(
            repoId: repoID,
            reason: reason,
            updatedAt: ISO8601DateFormatter.shared.string(from: Date())
        ))
    }

    func clearAIAutoIgnored(repoID: Int64) async throws {
        try await repository.deleteAIAutoIgnoredRepo(repoId: repoID)
    }

    /// 保存本地 AI 规则。这里不经过 GitHub API，避免把 Starcat 私有上下文混进远端描述。
    func saveAIRule(
        listID: String,
        instruction: String,
        autoApplyEnabled: Bool
    ) async throws {
        let normalizedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        try await repository.upsertAIRule(GitHubStarListAIRule(
            listId: listID,
            instruction: normalizedInstruction,
            // 空规则不能参与自动整理，即使旧 UI 状态仍保留了开关值也必须收敛为 false。
            autoApplyEnabled: !normalizedInstruction.isEmpty && autoApplyEnabled,
            updatedAt: ISO8601DateFormatter.shared.string(from: Date())
        ))
    }

    @discardableResult
    func addRepo(
        _ repo: Repo,
        toList listID: String
    ) async throws -> GitHubStarListMembershipWriteLocation {
        let result = try await addRepo(repo, toLists: [listID])
        return result.location
    }

    /// 把同一仓库的多个批准建议合并成至多一次 GitHub mutation。
    ///
    /// 应用前重新读取最新 membership，保证用户在 AI 审核期间手动新增的其它 Lists 不会
    /// 被替换式 mutation 覆盖。目标已经全部存在时直接 no-op，实现安全重试幂等。
    @discardableResult
    func addRepo(
        _ repo: Repo,
        toLists requestedListIDs: Set<String>
    ) async throws -> GitHubStarListMembershipWriteResult {
        guard !requestedListIDs.isEmpty else {
            return GitHubStarListMembershipWriteResult(
                changedListIDs: [],
                location: try await currentWriteLocation(forRepo: repo.id)
            )
        }
        let existingListIDs = Set(try await repository.listIds(forRepo: repo.id))
        let addedListIDs = requestedListIDs.subtracting(existingListIDs)
        guard !addedListIDs.isEmpty else {
            return GitHubStarListMembershipWriteResult(
                changedListIDs: [],
                location: try await currentWriteLocation(forRepo: repo.id)
            )
        }
        let location = try await replaceRepoLists(
            repoID: repo.id,
            owner: repo.owner,
            name: repo.name,
            with: Array(existingListIDs.union(addedListIDs))
        )
        return GitHubStarListMembershipWriteResult(
            changedListIDs: addedListIDs,
            location: location
        )
    }

    @discardableResult
    func removeRepo(
        _ repo: Repo,
        fromList listID: String
    ) async throws -> GitHubStarListMembershipWriteLocation {
        var listIDs = Set(try await repository.listIds(forRepo: repo.id))
        listIDs.remove(listID)
        return try await replaceRepoLists(
            repoID: repo.id,
            owner: repo.owner,
            name: repo.name,
            with: Array(listIDs)
        )
    }

    /// 把一个仓库的 membership 精确替换成审核页当前勾选集合。
    /// 该入口用于编辑“已应用”结果，必须允许同时新增和移除分组。
    @discardableResult
    func setLists(
        for repo: Repo,
        listIDs: Set<String>
    ) async throws -> GitHubStarListMembershipWriteLocation {
        try await replaceRepoLists(
            repoID: repo.id,
            owner: repo.owner,
            name: repo.name,
            with: Array(listIDs)
        )
    }

    /// 用户显式要求同步某个本地分组时，绕过本轮 owner 失败缓存并重新探测授权。
    @discardableResult
    func retryLocalMembership(for repo: Repo) async throws -> GitHubStarListMembershipWriteLocation {
        locallyRestrictedOwners.remove(normalizedOwner(repo.owner))
        let desiredListIDs = try await repository.listIds(forRepo: repo.id)
        return try await replaceRepoLists(
            repoID: repo.id,
            owner: repo.owner,
            name: repo.name,
            with: desiredListIDs,
            forceRemote: true
        )
    }

    /// 重试全部本地覆盖。每个受限 owner 只探测一次，避免大量组织仓库重复失败。
    func retryPendingLocalMemberships() async -> GitHubStarListPendingMembershipSyncSummary {
        locallyRestrictedOwners.removeAll()
        return await reconcilePendingLocalMemberships()
    }

    /// 为一批仓库统一设置某个分组的 membership，同时保留它们已有的其它分组。
    ///
    /// GitHub 的 mutation 是替换式写入，因此每个仓库都必须先读取完整 membership，再只修改
    /// 当前目标分组。这样批量“勾选分组”不会退化成旧的单选移动语义。
    func updateRepos(
        _ targets: [BatchStarTarget],
        membershipIn listID: String,
        shouldBelong: Bool
    ) async -> GitHubStarListBatchMembershipSummary {
        guard !targets.isEmpty else {
            return GitHubStarListBatchMembershipSummary(
                total: 0,
                succeeded: 0,
                skipped: 0,
                failed: 0
            )
        }

        // 同一 owner 必须串行：首个仓库命中组织 OAuth 限制后，后续仓库才能直接走本地覆盖，
        // 避免三路并发同时发出已知必败的 GitHub 请求。不同 owner 之间仍可并行。
        var ownerOrder: [String] = []
        var targetsByOwner: [String: [BatchStarTarget]] = [:]
        for target in targets {
            let ownerKey = normalizedOwner(target.owner)
            if targetsByOwner[ownerKey] == nil {
                ownerOrder.append(ownerKey)
            }
            targetsByOwner[ownerKey, default: []].append(target)
        }
        let ownerBatches = ownerOrder.compactMap { targetsByOwner[$0] }

        var lanes = Array(repeating: [[BatchStarTarget]](), count: Self.batchMembershipConcurrency)
        for (index, batch) in ownerBatches.enumerated() {
            lanes[index % Self.batchMembershipConcurrency].append(batch)
        }
        let firstBatches = lanes[0]
        let secondBatches = lanes[1]
        let thirdBatches = lanes[2]

        // 固定三条 MainActor lane，网络 await 时彼此让出执行权。这里不用动态 TaskGroup，
        // 是为了避开 Swift 6 region-based isolation checker 对 actor-isolated group closure 的误报。
        async let firstLane = updateRepoBatches(
            firstBatches,
            membershipIn: listID,
            shouldBelong: shouldBelong
        )
        async let secondLane = updateRepoBatches(
            secondBatches,
            membershipIn: listID,
            shouldBelong: shouldBelong
        )
        async let thirdLane = updateRepoBatches(
            thirdBatches,
            membershipIn: listID,
            shouldBelong: shouldBelong
        )
        let partialSummaries = await [firstLane, secondLane, thirdLane]

        return GitHubStarListBatchMembershipSummary(
            total: targets.count,
            succeeded: partialSummaries.reduce(0) { $0 + $1.succeeded },
            skipped: partialSummaries.reduce(0) { $0 + $1.skipped },
            failed: partialSummaries.reduce(0) { $0 + $1.failed },
            savedLocally: partialSummaries.reduce(0) { $0 + $1.savedLocally }
        )
    }

    /// 一条 lane 内顺序领取 owner 批次；三条 lane 同时在途，整体并发上限固定为 3。
    private func updateRepoBatches(
        _ batches: [[BatchStarTarget]],
        membershipIn listID: String,
        shouldBelong: Bool
    ) async -> GitHubStarListBatchMembershipSummary {
        var summaries: [GitHubStarListBatchMembershipSummary] = []
        for batch in batches {
            guard !Task.isCancelled else { break }
            summaries.append(await updateRepoBatch(
                batch,
                membershipIn: listID,
                shouldBelong: shouldBelong
            ))
        }
        return GitHubStarListBatchMembershipSummary(
            total: summaries.reduce(0) { $0 + $1.total },
            succeeded: summaries.reduce(0) { $0 + $1.succeeded },
            skipped: summaries.reduce(0) { $0 + $1.skipped },
            failed: summaries.reduce(0) { $0 + $1.failed },
            savedLocally: summaries.reduce(0) { $0 + $1.savedLocally }
        )
    }

    /// 一个 owner 内顺序处理，跨 owner 由 `updateRepos` 以固定三个 Worker 调度。
    private func updateRepoBatch(
        _ targets: [BatchStarTarget],
        membershipIn listID: String,
        shouldBelong: Bool
    ) async -> GitHubStarListBatchMembershipSummary {
        var succeeded = 0
        var skipped = 0
        var failed = 0
        var savedLocally = 0

        for target in targets {
            guard !Task.isCancelled else { break }
            do {
                var listIDs = Set(try await repository.listIds(forRepo: target.ghRepoId))
                let didChange: Bool
                if shouldBelong {
                    didChange = listIDs.insert(listID).inserted
                } else {
                    didChange = listIDs.remove(listID) != nil
                }

                guard didChange else {
                    skipped += 1
                    continue
                }

                let location = try await replaceRepoLists(
                    repoID: target.ghRepoId,
                    owner: target.owner,
                    name: target.name,
                    with: Array(listIDs)
                )
                succeeded += 1
                if location == .local {
                    savedLocally += 1
                }
            } catch {
                failed += 1
                AppLog.network.error("GitHub star list batch membership update failed for \(target.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return GitHubStarListBatchMembershipSummary(
            total: targets.count,
            succeeded: succeeded,
            skipped: skipped,
            failed: failed,
            savedLocally: savedLocally
        )
    }

    /// 先尝试 GitHub；只有可识别的组织 OAuth 限制才保存本地完整期望。
    private func replaceRepoLists(
        repoID: Int64,
        owner: String,
        name: String,
        with listIDs: [String],
        forceRemote: Bool = false
    ) async throws -> GitHubStarListMembershipWriteLocation {
        let sortedIDs = Array(Set(listIDs)).sorted()
        let ownerKey = normalizedOwner(owner)

        if !forceRemote, locallyRestrictedOwners.contains(ownerKey) {
            try Task.checkCancellation()
            try await repository.setLocalListIds(
                forRepo: repoID,
                listIds: sortedIDs,
                failureReason: GitHubStarListAIAutoIgnoreReason.organizationOAuthRestriction.rawValue
            )
            return .local
        }

        do {
            _ = try await apiClient.updateUserListsForRepository(
                owner: owner,
                name: name,
                listIds: sortedIDs
            )
            // 账号切换会取消批量队列。远端 mutation 若恰好已完成，仍必须在写当前数据库前
            // 再检查一次取消，避免旧账号结果落进刚切换的新账号作用域；旧账号下次同步会回读远端。
            try Task.checkCancellation()
            try await repository.setListIds(forRepo: repoID, listIds: sortedIDs)
            locallyRestrictedOwners.remove(ownerKey)
            return .github
        } catch {
            guard Self.isOrganizationOAuthRestriction(error) else { throw error }
            // 降级写本地前同样检查取消，避免旧账号的失败回调污染新账号数据库。
            try Task.checkCancellation()
            locallyRestrictedOwners.insert(ownerKey)
            try await repository.setLocalListIds(
                forRepo: repoID,
                listIds: sortedIDs,
                failureReason: error.localizedDescription
            )
            return .local
        }
    }

    private func currentWriteLocation(forRepo repoID: Int64) async throws -> GitHubStarListMembershipWriteLocation {
        if try await repository.hasLocalListOverrides(forRepo: repoID) {
            return .local
        }
        return .github
    }

    private func reconcilePendingLocalMemberships() async -> GitHubStarListPendingMembershipSyncSummary {
        let pending: [GitHubStarListPendingMembershipSync]
        do {
            pending = try await repository.fetchPendingLocalMembershipSyncs()
        } catch {
            AppLog.database.error("Load pending GitHub star list memberships failed: \(error.localizedDescription, privacy: .public)")
            return GitHubStarListPendingMembershipSyncSummary(total: 0, synced: 0, stillPending: 0, failed: 1)
        }

        var synced = 0
        var stillPending = 0
        var failed = 0
        for item in pending {
            guard !Task.isCancelled else { break }
            do {
                let location = try await replaceRepoLists(
                    repoID: item.repo.id,
                    owner: item.repo.owner,
                    name: item.repo.name,
                    with: Array(item.desiredListIDs)
                )
                switch location {
                case .github:
                    synced += 1
                case .local:
                    stillPending += 1
                }
            } catch {
                // 账号切换会取消旧同步；此时直接停止，不能把剩余待回写项误记为网络失败。
                guard !Task.isCancelled else { break }
                failed += 1
                AppLog.network.error("GitHub star list local override reconciliation failed for \(item.repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return GitHubStarListPendingMembershipSyncSummary(
            total: pending.count,
            synced: synced,
            stillPending: stillPending,
            failed: failed
        )
    }

    private func normalizedOwner(_ owner: String) -> String {
        owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// GraphQL mutation 的 HTTP 状态通常仍是 200，因此必须匹配 GraphQL message，不能按 403 粗判。
    private static func isOrganizationOAuthRestriction(_ error: Error) -> Bool {
        guard let networkError = error as? NetworkError,
              case .clientError(_, let message) = networkError else {
            return false
        }
        let normalized = (message ?? "").lowercased()
        return normalized.contains("organization has enabled oauth app access restrictions")
            || normalized.contains("third-parties is limited")
    }

    private func requireList(id: String) async throws -> GitHubStarList {
        if let list = try await repository.findList(id: id) {
            return list
        }
        throw DatabaseError.openFailed(underlying: NSError(
            domain: "GitHubStarListSyncService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "GitHub star list not found after local write: \(id)"]
        ))
    }
}
