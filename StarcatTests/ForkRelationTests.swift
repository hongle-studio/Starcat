//
//  ForkRelationTests.swift
//  StarcatTests
//
//  Fork 详情分流、GraphQL compare 方向映射、Contribute URL。
//  这些是纯函数：方向一旦写反，Sync / Contribute 会跟 GitHub 网页横幅对不上。
//

import Testing
import Foundation
@testable import Starcat

@Suite("Fork relation helpers")
struct ForkRelationTests {

    @Test("GraphQL compare 打在 fork 上时 ahead/behind 必须对调")
    func invertGraphQLCompare() {
        // 上游多 1217，fork 自己多 2 → GraphQL aheadBy=1217, behindBy=2
        let mapped = GitHubForkCompareMapping.uiAheadBehind(graphQLAheadBy: 1217, graphQLBehindBy: 2)
        #expect(mapped.ahead == 2)
        #expect(mapped.behind == 1217)
    }

    @Test("未登录或看别人的仓 → 打开 fork 页")
    func othersRepoOpensForkPage() {
        #expect(
            RepoForkStatKindResolver.kind(isFork: true, repoOwner: "dong4j", currentLogin: nil)
            == .forkOthersRepo
        )
        #expect(
            RepoForkStatKindResolver.kind(isFork: false, repoOwner: "xuxueli", currentLogin: "dong4j")
            == .forkOthersRepo
        )
    }

    @Test("自己的原创仓 → 查看 forks 网络")
    func ownOriginalViewsNetwork() {
        #expect(
            RepoForkStatKindResolver.kind(isFork: false, repoOwner: "Dong4j", currentLogin: "dong4j")
            == .viewOwnForks
        )
    }

    @Test("自己的 fork → 管理菜单")
    func ownForkShowsMenu() {
        #expect(
            RepoForkStatKindResolver.kind(isFork: true, repoOwner: "dong4j", currentLogin: "dong4j")
            == .manageOwnFork
        )
    }

    @Test("Contribute URL 使用 parent...fork 三段式 compare")
    func contributeURL() {
        let url = GitHubURLs.forkContribute(
            parentOwner: "xuxueli",
            parentRepo: "xxl-job",
            parentBranch: "master",
            forkOwner: "dong4j",
            forkRepo: "xxl-job",
            forkBranch: "master"
        )
        #expect(
            url.absoluteString
            == "https://github.com/xuxueli/xxl-job/compare/master...dong4j:xxl-job:master"
        )
    }

    @Test("落后时 needsSync，超前时 canContribute")
    func relationFlags() {
        let relation = Self.sampleRelation(aheadBy: 2, behindBy: 1217)
        #expect(relation.needsSync)
        #expect(relation.canContribute)
    }

    @Test("Sync 成功后 behind 立刻视为 0，ahead 自己的提交还在")
    func markingUpstreamSyncedClearsBehindOnly() {
        let synced = Self.sampleRelation(aheadBy: 2, behindBy: 1217).markingUpstreamSynced()
        #expect(synced.behindBy == 0)
        #expect(synced.aheadBy == 2)
        #expect(!synced.needsSync)
        #expect(synced.canContribute)
    }

    private static func sampleRelation(aheadBy: Int?, behindBy: Int?) -> GitHubForkRelation {
        GitHubForkRelation(
            parentFullName: "xuxueli/xxl-job",
            parentHTMLURL: GitHubURLs.repo(fullName: "xuxueli/xxl-job"),
            parentOwner: "xuxueli",
            parentRepoName: "xxl-job",
            parentDefaultBranch: "master",
            forkDefaultBranch: "master",
            aheadBy: aheadBy,
            behindBy: behindBy
        )
    }
}

@Suite("Fork relation session store")
@MainActor
struct ForkRelationSessionStoreTests {

    @Test("loader 失败不得把已有 parent 清成上游不可用")
    func failedReloadKeepsSnapshot() async {
        let store = ForkRelationSessionStore()
        let first = ForkRelationTestsHelper.relation(behindBy: 464)
        _ = await store.load(repoId: 1) { first }
        _ = await store.load(repoId: 1, force: true) { nil }
        #expect(store.relation(for: 1)?.parentFullName == first.parentFullName)
        #expect(store.relation(for: 1)?.behindBy == 464)
    }

    @Test("force 刷新必须丢弃同步前的 inFlight，不能把旧的 behind 写回来")
    func forceDoesNotReuseStaleInFlight() async {
        let store = ForkRelationSessionStore()
        let stale = ForkRelationTestsHelper.relation(behindBy: 464)
        let fresh = ForkRelationTestsHelper.relation(behindBy: 0)

        let slow = Task {
            await store.load(repoId: 7) {
                try? await Task.sleep(for: .milliseconds(250))
                return stale
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        let forced = await store.load(repoId: 7, force: true) { fresh }
        #expect(forced?.behindBy == 0)
        _ = await slow.value
        #expect(store.relation(for: 7)?.behindBy == 0)
    }

    @Test("新快照没有 compare 数字时保留已有 ahead/behind")
    func applyKeepsExistingCompareWhenMissing() async {
        let store = ForkRelationSessionStore()
        _ = await store.load(repoId: 3) { ForkRelationTestsHelper.relation(behindBy: 0) }
        _ = await store.load(repoId: 3, force: true) {
            ForkRelationTestsHelper.relation(aheadBy: nil, behindBy: nil)
        }
        #expect(store.relation(for: 3)?.behindBy == 0)
    }
}

private enum ForkRelationTestsHelper {
    static func relation(aheadBy: Int? = 0, behindBy: Int?) -> GitHubForkRelation {
        GitHubForkRelation(
            parentFullName: "HD838A/remote-mic-app",
            parentHTMLURL: GitHubURLs.repo(fullName: "HD838A/remote-mic-app"),
            parentOwner: "HD838A",
            parentRepoName: "remote-mic-app",
            parentDefaultBranch: "main",
            forkDefaultBranch: "main",
            aheadBy: aheadBy,
            behindBy: behindBy
        )
    }
}
