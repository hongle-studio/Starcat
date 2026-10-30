//
//  RepositoryContributorHeroViewModelTests.swift
//  StarcatTests
//
//  验证详情 Hero 贡献者列的 cache-first、溢出人数与样本份额口径。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Repository contributor hero")
struct RepositoryContributorHeroViewModelTests {
    @Test("首帧就必须占位，否则空 Group 会导致 .task 不跑")
    func showsColumnOnFirstFrame() {
        let service = ContributorHeroServiceStub(
            cached: nil,
            refreshed: insight([contributor("later", commits: 1)])
        )
        let viewModel = RepositoryContributorHeroViewModel(service: service)
        #expect(viewModel.isLoading)
        #expect(viewModel.shouldShowColumn)
    }

    @Test("成功但空样本时隐藏列")
    func emptySampleHidesColumn() async {
        let service = ContributorHeroServiceStub(
            cached: nil,
            refreshed: insight([])
        )
        let viewModel = RepositoryContributorHeroViewModel(service: service)

        await viewModel.load(repo: makeRepo(id: 10), isAuthenticated: true)

        #expect(viewModel.contributors.isEmpty)
        #expect(viewModel.shouldShowColumn == false)
        #expect(await service.refreshCount == 1)
    }

    @Test("超过 3 人时溢出人数是样本人数减 3")
    func overflowCountUsesSampleMinusVisible() {
        #expect(RepositoryContributorHeroViewModel.overflowCount(total: 0) == 0)
        #expect(RepositoryContributorHeroViewModel.overflowCount(total: 3) == 0)
        #expect(RepositoryContributorHeroViewModel.overflowCount(total: 12) == 9)
    }

    @Test("占比条和百分比都相对样本 commits 合计")
    func sampleShareUsesTotalCommits() {
        #expect(RepositoryContributorHeroViewModel.sampleShare(commits: 1, total: 4) == 0.25)
        #expect(RepositoryContributorHeroViewModel.sampleShare(commits: 80, total: 100) == 0.8)
        #expect(RepositoryContributorHeroViewModel.sampleShare(commits: 0, total: 10) == 0)
        #expect(RepositoryContributorHeroViewModel.sampleShare(commits: 9, total: 0) == 0)
        #expect(RepositoryContributorHeroViewModel.sampleTotal([
            contributor("a", commits: 3),
            contributor("b", commits: 1)
        ]) == 4)
    }

    @Test("Owner 判定忽略 login 大小写")
    func ownerMatchIgnoresCase() {
        #expect(RepositoryContributorHeroViewModel.isOwner(login: "MxYng", repoOwner: "mxyng"))
        #expect(RepositoryContributorHeroViewModel.isOwner(login: "other", repoOwner: "mxyng") == false)
    }

    @Test("贡献者图表页走 graphs/contributors")
    func contributorsGraphURL() {
        #expect(
            GitHubURLs.repoContributors(owner: "mxyng", repo: "ollama").absoluteString
                == "https://github.com/mxyng/ollama/graphs/contributors"
        )
    }

    @Test("新鲜缓存直接上屏且不刷新网络")
    func freshCacheSkipsRefresh() async {
        let cachedPeople = [
            contributor("alpha", commits: 20),
            contributor("beta", commits: 8),
            contributor("gamma", commits: 3),
            contributor("delta", commits: 1)
        ]
        let service = ContributorHeroServiceStub(
            cached: cachedInsight(cachedPeople, isStale: false),
            refreshed: insight([contributor("network", commits: 99)])
        )
        let viewModel = RepositoryContributorHeroViewModel(service: service)

        await viewModel.load(repo: makeRepo(id: 11), isAuthenticated: true)

        #expect(viewModel.contributors.map(\.login) == ["alpha", "beta", "gamma", "delta"])
        #expect(viewModel.visibleAvatars.map(\.login) == ["alpha", "beta", "gamma"])
        #expect(viewModel.overflowCount == 1)
        #expect(await service.refreshCount == 0)
    }

    @Test("过期缓存先上屏再被网络结果替换")
    func staleCacheRefreshes() async {
        let service = ContributorHeroServiceStub(
            cached: cachedInsight([contributor("old", commits: 1)], isStale: true),
            refreshed: insight([
                contributor("fresh", commits: 40),
                contributor("other", commits: 2)
            ])
        )
        let viewModel = RepositoryContributorHeroViewModel(service: service)

        await viewModel.load(repo: makeRepo(id: 12), isAuthenticated: true)

        #expect(viewModel.contributors.map(\.login) == ["fresh", "other"])
        #expect(await service.refreshCount == 1)
    }

    @Test("门禁拒绝时不发请求并隐藏列")
    func accessDeniedHidesColumn() async {
        let service = ContributorHeroServiceStub(
            allowLoad: false,
            cached: cachedInsight([contributor("hidden", commits: 9)], isStale: false),
            refreshed: insight([contributor("network", commits: 1)])
        )
        let viewModel = RepositoryContributorHeroViewModel(service: service)

        await viewModel.load(repo: makeRepo(id: 13), isAuthenticated: false)

        #expect(viewModel.contributors.isEmpty)
        #expect(viewModel.shouldShowColumn == false)
        #expect(await service.refreshCount == 0)
        #expect(await service.cacheCount == 0)
    }

    private func contributor(_ login: String, commits: Int) -> RepositoryContributor {
        RepositoryContributor(
            id: login,
            login: login,
            commits: commits,
            colorName: "purple"
        )
    }

    private func insight(_ contributors: [RepositoryContributor]) -> RepositoryContributorsInsight {
        RepositoryContributorsInsight(contributors: contributors, generatedAt: Date(timeIntervalSince1970: 1_000))
    }

    private func cachedInsight(
        _ contributors: [RepositoryContributor],
        isStale: Bool
    ) -> RepositoryCachedContributorsInsight {
        RepositoryCachedContributorsInsight(
            value: insight(contributors),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            isStale: isStale
        )
    }

    private func makeRepo(id: Int64) -> Repo {
        Repo(
            id: id,
            owner: "tasselx",
            name: "Keyden",
            fullName: "tasselx/Keyden",
            description: nil,
            language: "Swift",
            starsCount: 1,
            forksCount: 0,
            watchersCount: 1,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/tasselx/Keyden",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }
}

private actor ContributorHeroServiceStub: RepositoryContributorHeroServing {
    let allowLoad: Bool
    let cached: RepositoryCachedContributorsInsight?
    let refreshed: RepositoryContributorsInsight
    private(set) var refreshCount = 0
    private(set) var cacheCount = 0

    init(
        allowLoad: Bool = true,
        cached: RepositoryCachedContributorsInsight?,
        refreshed: RepositoryContributorsInsight
    ) {
        self.allowLoad = allowLoad
        self.cached = cached
        self.refreshed = refreshed
    }

    func allowsLoad(repo: Repo, isAuthenticated: Bool) async -> Bool {
        allowLoad
    }

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight? {
        cacheCount += 1
        return cached
    }

    func refreshContributors(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryContributorsInsight {
        refreshCount += 1
        return refreshed
    }
}
