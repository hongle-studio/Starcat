//
//  ExternalStarInboxTests.swift
//  StarcatTests
//
//  外部新增星标收件箱：头像槽位、探测累加、ETag 隔离、门控与清队列。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("ExternalStarInbox")
struct ExternalStarInboxTests {

    @Test("1/2/3 pending items render avatars only")
    func presentationAvatarsOnlyWhenAtMostThree() {
        let items = (1...3).map(Self.makeItem)
        let slots = ExternalStarInboxPresentation.slots(from: items)
        #expect(slots.count == 3)
        #expect(slots.allSatisfy { if case .avatar = $0 { true } else { false } })
    }

    @Test("4 items become 3 avatars plus +1")
    func presentationOverflowFour() {
        let slots = ExternalStarInboxPresentation.slots(from: (1...4).map(Self.makeItem))
        #expect(slots.count == 4)
        guard case .overflow(let count) = slots.last else {
            Issue.record("expected overflow slot")
            return
        }
        #expect(count == 1)
    }

    @Test("5 items become 3 avatars plus +2")
    func presentationOverflowFive() {
        let slots = ExternalStarInboxPresentation.slots(from: (1...5).map(Self.makeItem))
        #expect(slots.count == 4)
        guard case .overflow(let count) = slots.last else {
            Issue.record("expected overflow slot")
            return
        }
        #expect(count == 2)
        if case .avatar(let repoID, _, _) = slots[0] {
            #expect(repoID == 1)
        } else {
            Issue.record("newest item should stay first")
        }
    }

    @Test("304 leaves pending empty and does not rewrite sync ETag")
    func pollNotModifiedKeepsSyncETag() async throws {
        let env = try makeEnv()
        try await seedLastSync(env, userID: 1)
        try await env.repository.updateStarsETag(userID: 1, etag: "\"sync\"")
        env.api.starredReposHandler = { _, _, _ in
            throw NetworkError.notModified(etag: "\"sync\"")
        }
        await env.inbox.poll()
        #expect(env.inbox.pending.isEmpty)
        #expect(try await env.repository.fetchStarsETag(userID: 1) == "\"sync\"")
    }

    @Test("new remote IDs accumulate newest first and skip duplicates")
    func pollAccumulatesNewIDs() async throws {
        let env = try makeEnv()
        try await seedLastSync(env, userID: 1)
        env.api.starredReposHandler = { _, _, _ in
            env.inbox.pending.isEmpty
                ? env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e1\"")
                : env.onePage(
                    [env.makeDTO(id: 11, login: "b"), env.makeDTO(id: 10, login: "a")],
                    etag: "\"e2\""
                )
        }
        await env.inbox.poll()
        #expect(env.inbox.pending.map(\.repoID) == [10])
        await env.inbox.poll()
        #expect(env.inbox.pending.map(\.repoID) == [11, 10])
    }

    @Test("locally starred remote IDs never enter pending")
    func pollIgnoresLocalStarred() async throws {
        let env = try makeEnv()
        try await seedLastSync(env, userID: 1)
        try await env.repository.upsertStarred(
            [env.makeDTO(id: 10, login: "a")],
            userID: 1,
            syncedAt: Date()
        )
        env.api.starredReposHandler = { _, _, _ in
            env.onePage(
                [env.makeDTO(id: 10, login: "a"), env.makeDTO(id: 11, login: "b")],
                etag: "\"e1\""
            )
        }
        await env.inbox.poll()
        #expect(env.inbox.pending.map(\.repoID) == [11])
    }

    @Test("successful probe must not write the sync stars ETag")
    func pollMustNotPersistSyncETag() async throws {
        let env = try makeEnv()
        try await seedLastSync(env, userID: 1)
        try await env.repository.updateStarsETag(userID: 1, etag: "\"sync\"")
        env.api.starredReposHandler = { _, _, ifNoneMatch in
            #expect(ifNoneMatch == nil || ifNoneMatch == "\"probe\"")
            return env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"probe\"")
        }
        await env.inbox.poll()
        #expect(try await env.repository.fetchStarsETag(userID: 1) == "\"sync\"")
    }

    @Test("poll is no-op while syncing, rate limited, signed out, or inactive")
    func pollGates() async throws {
        let env = try makeEnv()
        try await seedLastSync(env, userID: 1)
        var calls = 0
        env.api.starredReposHandler = { _, _, _ in
            calls += 1
            return env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e\"")
        }

        env.sync.state = .syncing
        await env.inbox.poll()
        env.sync.state = .rateLimited(retryAt: Date().addingTimeInterval(60))
        await env.inbox.poll()
        env.sync.state = .idle

        let signedOut = ExternalStarInbox(
            apiClient: env.api,
            repository: env.repository,
            syncManager: env.sync,
            userIDProvider: { nil },
            isAppActive: { true }
        )
        await signedOut.poll()

        let inactive = ExternalStarInbox(
            apiClient: env.api,
            repository: env.repository,
            syncManager: env.sync,
            userIDProvider: { 1 },
            isAppActive: { false }
        )
        await inactive.poll()

        #expect(calls == 0)
    }

    @Test("start does not begin looping in the test host")
    func startSkippedInTests() throws {
        let env = try makeEnv()
        env.inbox.start()
        #expect(env.inbox.isLoopRunning == false)
    }

    @Test("apply dismisses pending immediately, before sync finishes")
    func applyClearsPendingImmediately() async throws {
        let env = try makeEnv()
        try await seedLastSync(env, userID: 1)
        env.api.starredReposHandler = { _, _, _ in
            env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e\"")
        }
        await env.inbox.poll()
        #expect(env.inbox.pending.map(\.repoID) == [10])

        env.api.starredReposHandler = { _, _, _ in
            env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e2\"")
        }
        env.inbox.apply()
        #expect(env.inbox.pending.isEmpty)
        try await waitUntil(env.sync) { state in
            if case .completed = state { return true }
            return false
        }
        await env.inbox.handleSyncCompleted()
        #expect(env.inbox.pending.isEmpty)
    }

    @Test("apply still dismisses pending if the following sync fails")
    func applyClearsPendingEvenIfSyncFails() async throws {
        let env = try makeEnv()
        try await seedLastSync(env, userID: 1)
        env.api.starredReposHandler = { _, _, _ in
            env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e\"")
        }
        await env.inbox.poll()
        env.api.starredReposHandler = { _, _, _ in
            throw NetworkError.unauthorized
        }
        env.inbox.apply()
        #expect(env.inbox.pending.isEmpty)
        try await waitUntil(env.sync) { state in
            if case .failed = state { return true }
            return false
        }
        await env.inbox.handleSyncCompleted()
        #expect(env.inbox.pending.isEmpty)
    }

    @Test("sync start from another entry also dismisses pending")
    func handleSyncStartedClearsPending() async throws {
        let env = try makeEnv()
        try await seedLastSync(env, userID: 1)
        env.api.starredReposHandler = { _, _, _ in
            env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e\"")
        }
        await env.inbox.poll()
        env.inbox.handleSyncStarted()
        #expect(env.inbox.pending.isEmpty)
    }

    @Test("account change drops pending and probe ETag")
    func resetClearsProbeState() async throws {
        let env = try makeEnv()
        try await seedLastSync(env, userID: 1)
        env.api.starredReposHandler = { _, _, _ in
            env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"probe\"")
        }
        await env.inbox.poll()
        env.inbox.resetForAccountChange()
        #expect(env.inbox.pending.isEmpty)

        var sawIfNoneMatch: String?
        env.api.starredReposHandler = { _, _, ifNoneMatch in
            sawIfNoneMatch = ifNoneMatch
            return env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"probe2\"")
        }
        await env.inbox.poll()
        #expect(sawIfNoneMatch == nil)
    }

    // MARK: - Fixtures

    static func makeItem(_ repoID: Int64) -> ExternalStarInbox.Item {
        ExternalStarInbox.Item(
            repoID: repoID,
            ownerLogin: "o\(repoID)",
            avatarURL: "https://avatars.githubusercontent.com/u/\(repoID)",
            starredAt: "2026-09-18T00:00:00Z"
        )
    }

    private func makeEnv() throws -> Env {
        let api = MockGitHubAPIClient()
        let db = try InMemoryDatabaseManager()
        let repository = GRDBRepoRepository(database: db)
        let sync = SyncManager(apiClient: api, repository: repository, rateLimitBufferSeconds: 0)
        let inbox = ExternalStarInbox(
            apiClient: api,
            repository: repository,
            syncManager: sync,
            userIDProvider: { 1 },
            isAppActive: { true }
        )
        return Env(api: api, repository: repository, sync: sync, inbox: inbox)
    }

    private func seedLastSync(_ env: Env, userID: Int64) async throws {
        try await env.repository.updateSyncState(
            userID: userID,
            starredCount: 0,
            syncedCount: 0,
            status: "idle"
        )
    }

    private func waitUntil(
        _ sync: SyncManager,
        timeout: TimeInterval = 5,
        condition: @escaping (SyncState) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(sync.state) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("waitUntil timed out, state=\(sync.state)")
    }
}

@MainActor
private final class Env {
    let api: MockGitHubAPIClient
    let repository: GRDBRepoRepository
    let sync: SyncManager
    let inbox: ExternalStarInbox

    init(
        api: MockGitHubAPIClient,
        repository: GRDBRepoRepository,
        sync: SyncManager,
        inbox: ExternalStarInbox
    ) {
        self.api = api
        self.repository = repository
        self.sync = sync
        self.inbox = inbox
    }

    func onePage(_ dtos: [StarredRepoDTO], etag: String?) -> APIResponse<[StarredRepoDTO]> {
        APIResponse(
            value: dtos,
            linkHeader: LinkHeader(nextPage: nil, lastPage: 1),
            rateLimit: .empty,
            statusCode: 200,
            etag: etag
        )
    }

    func makeDTO(id: Int64, login: String) -> StarredRepoDTO {
        let user = GitHubUserDTO(
            id: id,
            login: login,
            name: nil,
            avatarUrl: "https://avatars.githubusercontent.com/u/\(id)"
        )
        let repo = GitHubRepoDTO(
            id: id,
            name: "r\(id)",
            fullName: "\(login)/r\(id)",
            owner: user,
            description: nil,
            language: "Swift",
            stargazersCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: [],
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(login)/r\(id)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: nil,
            defaultBranch: nil,
            disabled: nil,
            isTemplate: nil,
            score: nil
        )
        return StarredRepoDTO(starredAt: "2026-09-18T10:00:00Z", repo: repo)
    }
}
