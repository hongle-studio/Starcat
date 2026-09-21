//
//  RepositoryContributorHeroViewModel.swift
//  Starcat
//
//  详情 Hero 贡献者列的轻量状态机：cache-first，过期再刷新，失败保旧值。
//

import Foundation
import Observation

/// 进入仓库详情后才拉贡献者样本；GitHub 接口只保证前 12 人，UI 不得把它说成全量人数。
@MainActor
@Observable
final class RepositoryContributorHeroViewModel {
    static let visibleAvatarLimit = 3

    private(set) var contributors: [RepositoryContributor] = []
    /// 首帧就必须为 true：列一旦因 `shouldShowColumn == false` 变成空 Group，
    /// macOS 上 `.task` 经常不调度，贡献者会永远不出现。有数据后保持 false，避免刷新闪骨架。
    private(set) var isLoading = true

    private let service: any RepositoryContributorHeroServing
    private var activeRequestID: UUID?

    init(service: any RepositoryContributorHeroServing) {
        self.service = service
    }

    var visibleAvatars: [RepositoryContributor] {
        Array(contributors.prefix(Self.visibleAvatarLimit))
    }

    var overflowCount: Int {
        Self.overflowCount(total: contributors.count)
    }

    var shouldShowColumn: Bool {
        isLoading || !contributors.isEmpty
    }

    /// 先显示本地缓存；缓存仍新鲜时不发网络，过期时保留旧值并后台刷新。
    ///
    /// `activeRequestID` 与 Task cancellation 双重守卫快速切仓的迟到响应，避免 A 仓
    /// 的网络结果覆盖 B 仓的头像。加载失败时保留已上屏缓存；cache miss 则整列隐藏。
    func load(repo: Repo, isAuthenticated: Bool) async {
        let requestID = UUID()
        activeRequestID = requestID
        contributors = []
        isLoading = true

        guard await service.allowsLoad(repo: repo, isAuthenticated: isAuthenticated) else {
            guard isCurrent(requestID) else { return }
            isLoading = false
            return
        }

        var cached: RepositoryCachedContributorsInsight?
        do {
            cached = try await service.cachedContributors(repoID: repo.id)
        } catch {
            cached = nil
        }

        guard isCurrent(requestID) else { return }
        if let cached {
            contributors = Self.normalized(cached.value.contributors)
            isLoading = false
            if !cached.isStale {
                return
            }
        }

        do {
            let fresh = try await service.refreshContributors(
                repository: RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name),
                ifNoneMatch: cached?.responseETag
            )
            guard isCurrent(requestID) else { return }
            contributors = Self.normalized(fresh.contributors)
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(requestID) else { return }
            isLoading = false
        }
    }

    static func overflowCount(total: Int) -> Int {
        max(0, total - visibleAvatarLimit)
    }

    /// 占比条和百分比都相对样本 commits 合计，合计为 100%。
    static func sampleShare(commits: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(max(commits, 0)) / Double(total))
    }

    static func sampleTotal(_ contributors: [RepositoryContributor]) -> Int {
        contributors.reduce(0) { $0 + max($1.commits, 0) }
    }

    /// GitHub login 大小写不敏感，Owner 徽章必须跟 `repo.owner` 忽略大小写比较。
    static func isOwner(login: String, repoOwner: String) -> Bool {
        login.compare(repoOwner, options: .caseInsensitive) == .orderedSame
    }

    static func normalized(_ contributors: [RepositoryContributor]) -> [RepositoryContributor] {
        contributors
            .filter { !$0.login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.commits > $1.commits }
    }

    private func isCurrent(_ requestID: UUID) -> Bool {
        !Task.isCancelled && activeRequestID == requestID
    }
}
