//
//  RepositoryContributorHeroService.swift
//  Starcat
//
//  详情 Hero 贡献者列的数据边界：复用洞察 contributors 缓存与 GitHub Metrics 刷新。
//
//  为什么单独拆：Hero 只需要 cache-first 的前 12 人样本，不能把洞察页整套
//  ViewModel / 202 轮询拖进元信息面板。私仓门禁与洞察远端拉取共用
//  `RepositoryRemoteInsightsAccessProviding`，避免 OAuth `public_repo` 打别人的私仓。
//

import Foundation

/// Hero 贡献者列依赖的最小数据协议，便于状态机在测试中验证 cache-first 与门禁。
protocol RepositoryContributorHeroServing: Sendable {
    func allowsLoad(repo: Repo, isAuthenticated: Bool) async -> Bool

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight?

    func refreshContributors(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryContributorsInsight
}

/// 把现有洞察远端 Provider 收成 Hero 可用的窄接口。
struct RepositoryContributorHeroService: RepositoryContributorHeroServing, Sendable {
    private let remote: any RepositoryRemoteInsightsProviding
    private let access: any RepositoryRemoteInsightsAccessProviding

    init(
        remote: any RepositoryRemoteInsightsProviding,
        access: any RepositoryRemoteInsightsAccessProviding
    ) {
        self.remote = remote
        self.access = access
    }

    func allowsLoad(repo: Repo, isAuthenticated: Bool) async -> Bool {
        // id=0 的 ephemeral 展示对象没有洞察缓存主键，也不该把身份发到 Metrics。
        guard repo.id > 0 else { return false }
        return await access.allowsRemoteInsights(repo: repo, isAuthenticated: isAuthenticated)
    }

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight? {
        try await remote.cachedContributors(repoID: repoID)
    }

    func refreshContributors(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryContributorsInsight {
        try await remote.refreshContributors(repository: repository, ifNoneMatch: ifNoneMatch)
    }
}
