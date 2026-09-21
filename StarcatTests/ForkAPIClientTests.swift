//
//  ForkAPIClientTests.swift
//  StarcatTests
//
//  forkRelation 必须真正把「落后 N 个提交」写进快照。
//  详情页 Sync / Contribute 用 `(behindBy ?? 0) > 0` 开关；
//  compare 失败若被吞成 nil，按钮会全部置灰，看起来像没调接口。
//

import Testing
import Foundation
@testable import Starcat

@Suite("Fork relation API", .serialized)
struct ForkAPIClientTests {

    private let baseURL = URL(string: "https://api.test.invalid")!

    private func makeClient() -> GitHubAPIClient {
        URLProtocolStub.reset()
        return GitHubAPIClient(
            baseURL: baseURL,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
    }

    private func httpResponse(_ statusCode: Int, _ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
    }

    /// GET /repos 的最小可解码 fork JSON。parent 必须带 default_branch，否则 headRef 会拼错。
    private var forkRepoJSON: Data {
        Data(#"""
        {
            "id": 1,
            "name": "remote-mic-app",
            "full_name": "dong4j/remote-mic-app",
            "owner": { "id": 2, "login": "dong4j" },
            "stargazers_count": 0,
            "forks_count": 0,
            "watchers_count": 0,
            "html_url": "https://github.com/dong4j/remote-mic-app",
            "private": false,
            "fork": true,
            "archived": false,
            "default_branch": "main",
            "parent": {
                "full_name": "HD838A/remote-mic-app",
                "html_url": "https://github.com/HD838A/remote-mic-app",
                "default_branch": "main"
            }
        }
        """#.utf8)
    }

    @Test("GraphQL compare 成功时 UI behind 必须等于上游多出来的 commit")
    func forkRelationMapsGraphQLCompare() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            switch request.url?.path {
            case "/repos/dong4j/remote-mic-app":
                return (self.httpResponse(200, request.url!), self.forkRepoJSON)
            case "/graphql":
                let body = Data(#"""
                {
                  "data": {
                    "repository": {
                      "defaultBranchRef": {
                        "compare": { "aheadBy": 464, "behindBy": 0, "status": "AHEAD" }
                      }
                    }
                  }
                }
                """#.utf8)
                return (self.httpResponse(200, request.url!), body)
            default:
                throw URLError(.badURL)
            }
        }

        let relation = try await client.forkRelation(owner: "dong4j", repo: "remote-mic-app")
        #expect(relation.parentFullName == "HD838A/remote-mic-app")
        #expect(relation.aheadBy == 0)
        #expect(relation.behindBy == 464)
        #expect(relation.needsSync)
        #expect(!relation.canContribute)
    }

    @Test("GraphQL 带 data 也带 errors 时仍采用 compare 数字，不能把 Sync 置灰")
    func forkRelationUsesPartialGraphQLData() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            switch request.url?.path {
            case "/repos/dong4j/remote-mic-app":
                return (self.httpResponse(200, request.url!), self.forkRepoJSON)
            case "/graphql":
                let body = Data(#"""
                {
                  "data": {
                    "repository": {
                      "defaultBranchRef": {
                        "compare": { "aheadBy": 464, "behindBy": 0 }
                      }
                    }
                  },
                  "errors": [
                    { "message": "Some non-fatal GraphQL warning" }
                  ]
                }
                """#.utf8)
                return (self.httpResponse(200, request.url!), body)
            default:
                throw URLError(.badURL)
            }
        }

        let relation = try await client.forkRelation(owner: "dong4j", repo: "remote-mic-app")
        #expect(relation.behindBy == 464)
        #expect(relation.needsSync)
    }

    @Test("GraphQL compare 为 null 时回退 REST ahead_by/behind_by")
    func forkRelationFallsBackToRESTCompare() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/repos/dong4j/remote-mic-app" {
                return (self.httpResponse(200, request.url!), self.forkRepoJSON)
            }
            if path == "/graphql" {
                let body = Data(#"""
                {"data":{"repository":{"defaultBranchRef":{"compare":null}}}}
                """#.utf8)
                return (self.httpResponse(200, request.url!), body)
            }
            if path.contains("/compare/") {
                let body = Data(#"""
                {"ahead_by":464,"behind_by":0,"status":"ahead","commits":[],"files":[]}
                """#.utf8)
                return (self.httpResponse(200, request.url!), body)
            }
            throw URLError(.badURL)
        }

        let relation = try await client.forkRelation(owner: "dong4j", repo: "remote-mic-app")
        #expect(relation.behindBy == 464)
        #expect(relation.needsSync)

        let compareRequest = URLProtocolStub.receivedRequests.first { ($0.url?.path ?? "").contains("/compare/") }
        let comparePath = try #require(compareRequest?.url?.path)
        #expect(comparePath.contains("main...HD838A:remote-mic-app:main"))
    }
}
