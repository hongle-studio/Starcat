//
//  GitHubStarListSyncServiceTests.swift
//  StarcatTests
//
//  验证 GitHub Lists membership 写入的远端优先、幂等与单次 mutation 约束。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("GitHubStarListSyncService", .serialized)
@MainActor
struct GitHubStarListSyncServiceTests {

    private let baseURL = URL(string: "https://api.test.invalid")!

    @Test("批量新增合并现有 membership，每仓库只发一次 mutation，重复调用 no-op")
    func addRepoToListsIsIdempotentAndUsesOneMutation() async throws {
        let environment = try await makeEnvironment(existingListIDs: ["list-a"])
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let query = try Self.graphQLQuery(from: request)
            if query.contains("repository(owner:") {
                return (Self.response(200, for: request), Data(#"{"data":{"repository":{"id":"repo-node"}}}"#.utf8))
            }
            return (Self.response(200, for: request), Data(#"{"data":{"updateUserListsForItem":{"lists":[]}}}"#.utf8))
        }

        let result = try await environment.service.addRepo(
            environment.repo,
            toLists: ["list-b", "list-c"]
        )
        #expect(result == GitHubStarListMembershipWriteResult(
            changedListIDs: ["list-b", "list-c"],
            location: .github
        ))
        #expect(try await environment.repository.listIds(forRepo: environment.repo.id) == ["list-a", "list-b", "list-c"])

        let mutationRequests = try URLProtocolStub.receivedRequests.filter {
            try Self.graphQLQuery(from: $0).contains("updateUserListsForItem")
        }
        #expect(mutationRequests.count == 1)
        let variables = try Self.graphQLVariables(from: #require(mutationRequests.first))
        #expect(variables["listIds"] as? [String] == ["list-a", "list-b", "list-c"])

        let requestCount = URLProtocolStub.receivedRequests.count
        let duplicateAdd = try await environment.service.addRepo(
            environment.repo,
            toLists: ["list-b", "list-c"]
        )
        #expect(duplicateAdd.changedListIDs.isEmpty)
        #expect(duplicateAdd.location == .github)
        #expect(URLProtocolStub.receivedRequests.count == requestCount)
    }

    @Test("精确编辑 membership 可同时移除旧分组并加入新分组")
    func setListsReplacesRemoteAndLocalMemberships() async throws {
        let environment = try await makeEnvironment(existingListIDs: ["list-a", "list-b"])
        Self.stubSuccessfulMutations()

        try await environment.service.setLists(
            for: environment.repo,
            listIDs: ["list-b", "list-c"]
        )

        #expect(try await environment.repository.listIds(forRepo: environment.repo.id) == [
            "list-b", "list-c"
        ])
        let mutationRequests = try URLProtocolStub.receivedRequests.filter {
            try Self.graphQLQuery(from: $0).contains("updateUserListsForItem")
        }
        #expect(mutationRequests.count == 1)
        let variables = try Self.graphQLVariables(from: #require(mutationRequests.first))
        #expect(variables["listIds"] as? [String] == ["list-b", "list-c"])
    }

    @Test("远端 mutation 失败时不产生本地 membership，随后可安全重试")
    func remoteFailureDoesNotWriteLocalMembership() async throws {
        let environment = try await makeEnvironment(existingListIDs: ["list-a"])
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let query = try Self.graphQLQuery(from: request)
            if query.contains("repository(owner:") {
                return (Self.response(200, for: request), Data(#"{"data":{"repository":{"id":"repo-node"}}}"#.utf8))
            }
            throw URLError(.cannotConnectToHost)
        }

        await #expect(throws: (any Error).self) {
            _ = try await environment.service.addRepo(environment.repo, toLists: ["list-b"])
        }
        #expect(try await environment.repository.listIds(forRepo: environment.repo.id) == ["list-a"])
    }

    @Test("组织 OAuth 限制时保存本地覆盖，而普通网络错误仍保持失败")
    func organizationRestrictionFallsBackToLocalMembership() async throws {
        let environment = try await makeEnvironment(existingListIDs: ["list-a"])
        Self.stubOrganizationRestriction()

        let result = try await environment.service.addRepo(
            environment.repo,
            toLists: ["list-b"]
        )

        #expect(result == GitHubStarListMembershipWriteResult(
            changedListIDs: ["list-b"],
            location: .local
        ))
        #expect(try await environment.repository.remoteListIds(forRepo: 1) == ["list-a"])
        #expect(try await environment.repository.listIds(forRepo: 1) == ["list-a", "list-b"])
        #expect(try await environment.repository.hasLocalListOverrides(forRepo: 1))
    }

    @Test("同一受限组织一轮只探测一次，其余仓库直接保存本地")
    func organizationRestrictionIsCachedPerOwner() async throws {
        let environment = try await makeBatchEnvironment(
            existingListIDsByRepo: [
                "octo/one": ["list-a"],
                "octo/two": ["list-a"]
            ]
        )
        Self.stubOrganizationRestriction()

        let summary = await environment.service.updateRepos(
            environment.targets,
            membershipIn: "list-b",
            shouldBelong: true
        )

        #expect(summary == GitHubStarListBatchMembershipSummary(
            total: 2,
            succeeded: 2,
            skipped: 0,
            failed: 0,
            savedLocally: 2
        ))
        #expect(try await environment.repository.listIds(forRepo: 1) == ["list-a", "list-b"])
        #expect(try await environment.repository.listIds(forRepo: 2) == ["list-a", "list-b"])

        let mutationRequests = try URLProtocolStub.receivedRequests.filter {
            try Self.graphQLQuery(from: $0).contains("updateUserListsForItem")
        }
        #expect(mutationRequests.count == 1)
    }

    @Test("组织授权恢复后可把本地覆盖精确回写 GitHub")
    func retryPendingLocalMembershipsConvergesToRemote() async throws {
        let environment = try await makeEnvironment(existingListIDs: ["list-a"])
        Self.stubOrganizationRestriction()
        _ = try await environment.service.setLists(
            for: environment.repo,
            listIDs: ["list-b"]
        )
        #expect(try await environment.repository.listIds(forRepo: 1) == ["list-b"])

        Self.stubSuccessfulMutations()
        let summary = await environment.service.retryPendingLocalMemberships()

        #expect(summary == GitHubStarListPendingMembershipSyncSummary(
            total: 1,
            synced: 1,
            stillPending: 0,
            failed: 0
        ))
        #expect(try await environment.repository.remoteListIds(forRepo: 1) == ["list-b"])
        #expect(try await environment.repository.hasLocalListOverrides(forRepo: 1) == false)
    }

    @Test("批量勾选只补齐缺失 membership，并跳过已经属于目标分组的仓库")
    func batchMembershipAddPreservesExistingGroupsAndSkipsNoOp() async throws {
        let environment = try await makeBatchEnvironment(
            existingListIDsByRepo: [
                "octo/one": ["list-a", "list-b"],
                "octo/two": ["list-a"]
            ]
        )
        Self.stubSuccessfulMutations()

        let summary = await environment.service.updateRepos(
            environment.targets,
            membershipIn: "list-b",
            shouldBelong: true
        )

        #expect(summary == GitHubStarListBatchMembershipSummary(
            total: 2,
            succeeded: 1,
            skipped: 1,
            failed: 0
        ))
        #expect(try await environment.repository.listIds(forRepo: 1) == ["list-a", "list-b"])
        #expect(try await environment.repository.listIds(forRepo: 2) == ["list-a", "list-b"])

        let mutationRequests = try URLProtocolStub.receivedRequests.filter {
            try Self.graphQLQuery(from: $0).contains("updateUserListsForItem")
        }
        #expect(mutationRequests.count == 1)
    }

    @Test("批量取消勾选只移除目标 membership，并保留仓库所属的其它分组")
    func batchMembershipRemovePreservesOtherGroups() async throws {
        let environment = try await makeBatchEnvironment(
            existingListIDsByRepo: [
                "octo/one": ["list-a", "list-b"],
                "octo/two": ["list-a", "list-b", "list-c"]
            ]
        )
        Self.stubSuccessfulMutations()

        let summary = await environment.service.updateRepos(
            environment.targets,
            membershipIn: "list-b",
            shouldBelong: false
        )

        #expect(summary == GitHubStarListBatchMembershipSummary(
            total: 2,
            succeeded: 2,
            skipped: 0,
            failed: 0
        ))
        #expect(try await environment.repository.listIds(forRepo: 1) == ["list-a"])
        #expect(try await environment.repository.listIds(forRepo: 2) == ["list-a", "list-c"])
    }

    @Test("批量 membership 最多三路并发，同一 owner 仍保持串行")
    func batchMembershipUsesBoundedConcurrencyAcrossOwners() async throws {
        let targets = [
            BatchStarTarget(ghRepoId: 1, owner: "shared", name: "one"),
            BatchStarTarget(ghRepoId: 2, owner: "shared", name: "two"),
            BatchStarTarget(ghRepoId: 3, owner: "alpha", name: "one"),
            BatchStarTarget(ghRepoId: 4, owner: "beta", name: "one"),
            BatchStarTarget(ghRepoId: 5, owner: "gamma", name: "one"),
            BatchStarTarget(ghRepoId: 6, owner: "delta", name: "one")
        ]
        let probe = MembershipMutationConcurrencyProbe()
        let environment = try await makeBatchEnvironment(
            existingListIDsByRepo: Dictionary(uniqueKeysWithValues: targets.map { ($0.fullName, ["list-a"]) }),
            targets: targets,
            apiClient: ConcurrencyProbeGitHubStarListAPIClient(probe: probe)
        )

        let summary = await environment.service.updateRepos(
            targets,
            membershipIn: "list-b",
            shouldBelong: true
        )
        let snapshot = probe.snapshot()

        #expect(summary == GitHubStarListBatchMembershipSummary(
            total: targets.count,
            succeeded: targets.count,
            skipped: 0,
            failed: 0
        ))
        #expect(snapshot.maximumConcurrent == 3)
        #expect(snapshot.maximumConcurrentByOwner["shared"] == 1)
    }

    @Test("批量 membership 单条失败不阻断后续汇总，失败仓库不写本地")
    func batchMembershipFailureKeepsLocalState() async throws {
        let environment = try await makeBatchEnvironment(
            existingListIDsByRepo: [
                "octo/one": ["list-a"],
                "octo/two": ["list-a"]
            ]
        )
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let query = try Self.graphQLQuery(from: request)
            let variables = try Self.graphQLVariables(from: request)
            if query.contains("repository(owner:") {
                let name = try #require(variables["name"] as? String)
                let payload = "{\"data\":{\"repository\":{\"id\":\"repo-node-\(name)\"}}}"
                return (Self.response(200, for: request), Data(payload.utf8))
            }
            if variables["itemId"] as? String == "repo-node-two" {
                throw URLError(.cannotConnectToHost)
            }
            return (Self.response(200, for: request), Data(#"{"data":{"updateUserListsForItem":{"lists":[]}}}"#.utf8))
        }

        let summary = await environment.service.updateRepos(
            environment.targets,
            membershipIn: "list-b",
            shouldBelong: true
        )

        #expect(summary == GitHubStarListBatchMembershipSummary(
            total: 2,
            succeeded: 1,
            skipped: 0,
            failed: 1
        ))
        #expect(try await environment.repository.listIds(forRepo: 1) == ["list-a", "list-b"])
        #expect(try await environment.repository.listIds(forRepo: 2) == ["list-a"])
    }

    private func makeEnvironment(
        existingListIDs: [String]
    ) async throws -> (
        service: GitHubStarListSyncService,
        repository: GRDBGitHubStarListRepository,
        repo: Repo
    ) {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, owner: "octo", name: "one")
        let repository = GRDBGitHubStarListRepository(database: database)
        let remoteLists = ["list-a", "list-b", "list-c"].enumerated().map { index, id in
            GitHubStarListRemoteRecord(
                id: id,
                name: id,
                description: nil,
                isPrivate: false,
                position: index,
                createdAt: "2026-08-26T00:00:00Z",
                updatedAt: "2026-08-26T00:00:00Z"
            )
        }
        try await repository.replaceRemoteSnapshot(
            lists: remoteLists,
            memberships: existingListIDs.map {
                GitHubStarListRemoteMembership(listId: $0, repoFullName: "octo/one")
            },
            syncedAt: Date(timeIntervalSince1970: 0)
        )
        let repo = try await database.writer.read { db in
            try Repo.fetchOne(db, key: 1)
        }
        let requiredRepo = try #require(repo)
        let client = GitHubAPIClient(
            baseURL: baseURL,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
        return (
            GitHubStarListSyncService(apiClient: client, repository: repository),
            repository,
            requiredRepo
        )
    }

    private func makeBatchEnvironment(
        existingListIDsByRepo: [String: [String]],
        targets: [BatchStarTarget] = [
            BatchStarTarget(ghRepoId: 1, owner: "octo", name: "one"),
            BatchStarTarget(ghRepoId: 2, owner: "octo", name: "two")
        ],
        apiClient: (any GitHubStarListAPIClientProtocol)? = nil
    ) async throws -> (
        service: GitHubStarListSyncService,
        repository: GRDBGitHubStarListRepository,
        targets: [BatchStarTarget]
    ) {
        let database = try InMemoryDatabaseManager()
        for target in targets {
            try await database.insertRepoFixture(
                id: target.ghRepoId,
                owner: target.owner,
                name: target.name
            )
        }
        let repository = GRDBGitHubStarListRepository(database: database)
        let remoteLists = ["list-a", "list-b", "list-c"].enumerated().map { index, id in
            GitHubStarListRemoteRecord(
                id: id,
                name: id,
                description: nil,
                isPrivate: false,
                position: index,
                createdAt: "2026-08-26T00:00:00Z",
                updatedAt: "2026-08-26T00:00:00Z"
            )
        }
        let memberships = existingListIDsByRepo.flatMap { fullName, listIDs in
            listIDs.map {
                GitHubStarListRemoteMembership(listId: $0, repoFullName: fullName)
            }
        }
        try await repository.replaceRemoteSnapshot(
            lists: remoteLists,
            memberships: memberships,
            syncedAt: Date(timeIntervalSince1970: 0)
        )
        let client: any GitHubStarListAPIClientProtocol
        if let apiClient {
            client = apiClient
        } else {
            client = GitHubAPIClient(
                baseURL: baseURL,
                session: URLProtocolStub.ephemeralSession(),
                tokenProvider: StubTokenProvider(token: "test-token")
            )
        }
        return (
            GitHubStarListSyncService(apiClient: client, repository: repository),
            repository,
            targets
        )
    }

    private static func stubSuccessfulMutations() {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let query = try graphQLQuery(from: request)
            if query.contains("repository(owner:") {
                return (response(200, for: request), Data(#"{"data":{"repository":{"id":"repo-node"}}}"#.utf8))
            }
            return (response(200, for: request), Data(#"{"data":{"updateUserListsForItem":{"lists":[]}}}"#.utf8))
        }
    }

    private static func stubOrganizationRestriction() {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let query = try graphQLQuery(from: request)
            if query.contains("repository(owner:") {
                return (response(200, for: request), Data(#"{"data":{"repository":{"id":"repo-node"}}}"#.utf8))
            }
            let payload = #"{"data":{"updateUserListsForItem":null},"errors":[{"message":"Although you appear to have the correct authorization credentials, the organization has enabled OAuth App access restrictions."}]}"#
            return (response(200, for: request), Data(payload.utf8))
        }
    }

    private nonisolated static func graphQLQuery(from request: URLRequest) throws -> String {
        let object = try JSONSerialization.jsonObject(with: try #require(request.httpBody))
        let body = try #require(object as? [String: Any])
        return try #require(body["query"] as? String)
    }

    private nonisolated static func graphQLVariables(from request: URLRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try #require(request.httpBody))
        let body = try #require(object as? [String: Any])
        return try #require(body["variables"] as? [String: Any])
    }

    private nonisolated static func response(_ statusCode: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

/// URLProtocol Handler 是同步闭包，用锁记录并发区间，避免测试探针本身产生数据竞争。
private final class MembershipMutationConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var concurrent = 0
    private var maximumConcurrent = 0
    private var concurrentByOwner: [String: Int] = [:]
    private var maximumConcurrentByOwner: [String: Int] = [:]

    func begin(owner: String) {
        lock.withLock {
            concurrent += 1
            maximumConcurrent = max(maximumConcurrent, concurrent)
            concurrentByOwner[owner, default: 0] += 1
            maximumConcurrentByOwner[owner] = max(
                maximumConcurrentByOwner[owner, default: 0],
                concurrentByOwner[owner, default: 0]
            )
        }
    }

    func end(owner: String) {
        lock.withLock {
            concurrent -= 1
            concurrentByOwner[owner, default: 0] -= 1
        }
    }

    func snapshot() -> (maximumConcurrent: Int, maximumConcurrentByOwner: [String: Int]) {
        lock.withLock { (maximumConcurrent, maximumConcurrentByOwner) }
    }
}

/// 直接在 async API 边界挂起请求，验证服务调度；URLProtocol 的同步 Handler 自身可能串行执行。
@MainActor
private final class ConcurrencyProbeGitHubStarListAPIClient: GitHubStarListAPIClientProtocol {
    private let probe: MembershipMutationConcurrencyProbe

    init(probe: MembershipMutationConcurrencyProbe) {
        self.probe = probe
    }

    func starLists(login _: String) async throws -> GitHubStarListRemoteSnapshot {
        throw URLError(.unsupportedURL)
    }

    func createUserList(
        name _: String,
        description _: String?,
        isPrivate _: Bool
    ) async throws -> GitHubStarListRemoteRecord {
        throw URLError(.unsupportedURL)
    }

    func updateUserList(
        id _: String,
        name _: String,
        description _: String?,
        isPrivate _: Bool
    ) async throws -> GitHubStarListRemoteRecord {
        throw URLError(.unsupportedURL)
    }

    func deleteUserList(id _: String) async throws {
        throw URLError(.unsupportedURL)
    }

    func updateUserListsForRepository(
        owner: String,
        name _: String,
        listIds _: [String]
    ) async throws -> [GitHubStarListRemoteRecord] {
        probe.begin(owner: owner)
        defer { probe.end(owner: owner) }
        try await Task.sleep(for: .milliseconds(80))
        return []
    }
}
