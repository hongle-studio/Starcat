//
//  SearchCoordinatorTests.swift
//  StarcatTests
//
//  覆盖多 Provider 编排、部分失败、去重与 generation 防迟到覆盖。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Search Coordinator")
@MainActor
struct SearchCoordinatorTests {
    @Test("单个 Provider 失败不清空其它来源结果")
    func partialFailureKeepsSuccessfulResults() async {
        let repo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let success = StubSearchProvider(source: .localKeyword) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let failure = StubSearchProvider(source: .github) { _ in
            throw TestError.failed
        }
        let coordinator = SearchCoordinator(providers: [success, failure])

        await coordinator.search(SearchRequest(query: "swift"))

        #expect(coordinator.repositories.map { $0.card.fullName } == ["apple/swift"])
        if case .failed = coordinator.status(for: .github) {
            // expected
        } else {
            Issue.record("GitHub source should fail independently")
        }
    }

    @Test("All scope 合并关键词与语义结果并保持关键词优先")
    func allScopeMergesKeywordAndSemanticResults() async {
        let keywordRepo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let semanticOnlyRepo = Self.makeRepo(id: 2, owner: "swiftlang", name: "swift-evolution")
        let keyword = StubSearchProvider(source: .localKeyword) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: keywordRepo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let semantic = StubSearchProvider(source: .localSemantic) { _ in
            var exactCandidate = Self.makeCandidate(repo: keywordRepo, source: .localSemantic)
            exactCandidate.semanticScore = 0.95
            exactCandidate.semanticReason = "name match"
            var semanticCandidate = Self.makeCandidate(repo: semanticOnlyRepo, source: .localSemantic)
            semanticCandidate.semanticScore = 0.88
            return SearchProviderPage(
                repositories: [semanticCandidate, exactCandidate],
                references: [],
                totalCount: 2,
                hasNextPage: false
            )
        }
        let coordinator = SearchCoordinator(providers: [semantic, keyword])

        await coordinator.search(SearchRequest(query: "swift", scope: .all))

        #expect(coordinator.repositories.map { $0.card.fullName } == [
            "apple/swift",
            "swiftlang/swift-evolution"
        ])
        #expect(coordinator.repositories[0].sources == Set<SearchSource>([.localKeyword, .localSemantic]))
        #expect(coordinator.repositories[0].semanticScore == 0.95)
        #expect(coordinator.repositories[0].semanticReason == "name match")
    }

    @Test("跨来源同一 Repo 合并 sources 并优先保留本地状态")
    func mergeDeduplicatesRepositories() {
        let local = Self.makeRepo(id: 42, owner: "OpenAI", name: "Codex")
        let localCandidate = Self.makeCandidate(repo: local, source: .localKeyword)
        let remoteCard = RepoCardViewData(
            ghRepoId: 42,
            fullName: "openai/codex",
            owner: "openai",
            repo: "codex",
            avatarURL: nil,
            description: "remote",
            language: "Rust",
            starsCount: 100,
            forksCount: 10,
            isArchived: false,
            isFork: false,
            isPrivate: false,
            isStarred: false,
            isInLibrary: false,
            badge: nil,
            weeklySources: [],
            weeklySourceLabel: nil,
            inlineMetadata: nil,
            footerMetadata: nil,
            readStatus: nil,
            openSSFScore: nil,
            healthBadge: nil
        )
        let remote = RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: 42, owner: "openai", name: "codex"),
            card: remoteCard,
            sources: [.github],
            localRepo: nil,
            remoteRepo: nil,
            semanticScore: nil
        )

        let result = SearchCoordinator.mergeRepositories(existing: [remote], incoming: [localCandidate])

        #expect(result.count == 1)
        #expect(result[0].sources == Set<SearchSource>([.github, .localKeyword]))
        #expect(result[0].localRepo?.id == 42)
        #expect(result[0].card.description == "local")
    }

    @Test("原地更新 Repo 知识库状态")
    func updateRepositoryLibraryStateRefreshesLoadedCandidate() async {
        let repo = Self.makeRepo(id: 42, owner: "OpenAI", name: "Codex")
        let provider = StubSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .github)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let coordinator = SearchCoordinator(providers: [provider])

        await coordinator.search(SearchRequest(query: "codex", scope: .github))
        coordinator.updateRepositoryLibraryState(
            identity: RepoIdentity(ghRepoID: 42, owner: "openai", name: "codex"),
            state: .inLibrary,
            persistedRepo: repo
        )

        #expect(coordinator.repositories.first?.card.isInLibrary == true)
        #expect(coordinator.repositories.first?.localRepo?.id == 42)
    }

    @Test("空 query 清空结果和状态")
    func emptyQueryResets() async {
        let provider = StubSearchProvider(source: .localKeyword) { _ in .empty }
        let coordinator = SearchCoordinator(providers: [provider])
        await coordinator.search(SearchRequest(query: "swift"))
        await coordinator.search(SearchRequest(query: "   "))
        #expect(coordinator.repositories.isEmpty)
        #expect(coordinator.statuses.isEmpty)
    }

    @Test("切换 all → local 复用本地结果且不重跑 Provider")
    func updateScopeAllToLocalReusesLocalProviders() async {
        let localRepo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let githubRepo = Self.makeRepo(id: 2, owner: "torvalds", name: "linux")
        let keyword = CountingSearchProvider(
            source: .localKeyword,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: localRepo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let semantic = CountingSearchProvider(
            source: .localSemantic,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: localRepo, source: .localSemantic)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let github = CountingSearchProvider(
            source: .github,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: githubRepo, source: .github)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let coordinator = SearchCoordinator(providers: [keyword, semantic, github])

        await coordinator.search(SearchRequest(query: "swift", scope: .all))
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 1)
        #expect(coordinator.repositories.map(\.card.fullName).contains("torvalds/linux"))

        await coordinator.updateScope(SearchRequest(query: "swift", scope: .local))
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 1)
        #expect(!coordinator.repositories.map(\.card.fullName).contains("torvalds/linux"))
        #expect(coordinator.repositories.map(\.card.fullName) == ["apple/swift"])
    }

    @Test("切换 local → all 只补跑 GitHub")
    func updateScopeLocalToAllFetchesMissingGitHub() async {
        let localRepo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let githubRepo = Self.makeRepo(id: 2, owner: "torvalds", name: "linux")
        let keyword = CountingSearchProvider(
            source: .localKeyword,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: localRepo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let semantic = CountingSearchProvider(
            source: .localSemantic,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: localRepo, source: .localSemantic)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let github = CountingSearchProvider(
            source: .github,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: githubRepo, source: .github)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let coordinator = SearchCoordinator(providers: [keyword, semantic, github])

        await coordinator.search(SearchRequest(query: "swift", scope: .local))
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 0)

        await coordinator.updateScope(SearchRequest(query: "swift", scope: .all))
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 1)
        #expect(coordinator.repositories.map(\.card.fullName) == ["apple/swift", "torvalds/linux"])
    }

    @Test("切换 scope 不取消仍在进行的语义搜索")
    func updateScopeDoesNotCancelInFlightSemantic() async {
        let repo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let gate = SearchCoordinatorHoldGate()
        let keyword = CountingSearchProvider(
            source: .localKeyword,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let semantic = GatedCountingSearchProvider(
            source: .localSemantic,
            gate: gate,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .localSemantic)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let coordinator = SearchCoordinator(providers: [keyword, semantic])
        let searchTask = Task {
            await coordinator.search(SearchRequest(query: "swift", scope: .all))
        }
        await gate.waitUntilBlocked()
        await coordinator.updateScope(SearchRequest(query: "swift", scope: .local))
        #expect(semantic.callCount == 1)
        await gate.resume()
        await searchTask.value
        #expect(semantic.callCount == 1)
        if case .loaded = coordinator.status(for: .localSemantic) {
            // expected
        } else {
            Issue.record("semantic results should still land after scope switch")
        }
    }

    nonisolated fileprivate static func makeRepo(id: Int64, owner: String, name: String) -> Repo {
        Repo(
            id: id,
            owner: owner,
            name: name,
            fullName: "\(owner)/\(name)",
            description: "local",
            language: "Swift",
            starsCount: 10,
            forksCount: 2,
            watchersCount: 10,
            topics: nil,
            license: "Apache-2.0",
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
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

    nonisolated fileprivate static func makeCandidate(repo: Repo, source: SearchSource) -> RepositoryCandidate {
        RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name),
            card: repo.asCardData(),
            sources: [source],
            localRepo: repo,
            remoteRepo: nil,
            semanticScore: nil
        )
    }
}

private struct StubSearchProvider: SearchProvider {
    let source: SearchSource
    let handler: @Sendable (SearchRequest) async throws -> SearchProviderPage

    init(
        source: SearchSource,
        handler: @escaping @Sendable (SearchRequest) async throws -> SearchProviderPage
    ) {
        self.source = source
        self.handler = handler
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        try await handler(request)
    }
}

private final class CountingSearchProvider: SearchProvider, @unchecked Sendable {
    let source: SearchSource
    let page: SearchProviderPage
    private let lock = NSLock()
    private var value = 0

    var callCount: Int {
        lock.withLock { value }
    }

    init(source: SearchSource, page: SearchProviderPage) {
        self.source = source
        self.page = page
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        lock.withLock { value += 1 }
        return page
    }
}

private final class GatedCountingSearchProvider: SearchProvider, @unchecked Sendable {
    let source: SearchSource
    let gate: SearchCoordinatorHoldGate
    let page: SearchProviderPage
    private let lock = NSLock()
    private var value = 0

    var callCount: Int {
        lock.withLock { value }
    }

    init(source: SearchSource, gate: SearchCoordinatorHoldGate, page: SearchProviderPage) {
        self.source = source
        self.gate = gate
        self.page = page
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        lock.withLock { value += 1 }
        await gate.wait()
        return page
    }
}

/// 卡住单个 Provider，直到测试显式 resume。
private actor SearchCoordinatorHoldGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isBlocked = false
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if isBlocked || isReleased { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum TestError: Error {
    case failed
}
