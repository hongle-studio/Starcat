//
//  AmbientCatalogTests.swift
//  StarcatTests
//
//  保证本地 Catalog 把 Star 聚成 Owner，并区分真实空目录与 repository 故障。
//

import Testing
@testable import Starcat

@Suite("Ambient Catalog")
struct AmbientCatalogTests {
    private enum StubError: Error {
        case unavailable
    }

    @Test("成功读取 Star 并聚成 Owner")
    func loadsOwnerCards() async throws {
        var repo = Repo.makeMinimal(owner: "apple", name: "swift")
        repo.id = 10
        let catalog = LocalAmbientCatalog(loadStarred: { [repo] in [repo] })

        let cards = try await catalog.loadCards(scene: .owners)

        #expect(cards.map(\.id) == ["owner:apple"])
    }

    @Test("空 repository 保持真实空目录")
    func keepsEmptyCatalog() async throws {
        let catalog = LocalAmbientCatalog(loadStarred: { [] })

        #expect(try await catalog.loadCards(scene: .owners).isEmpty)
    }

    @Test("repository 错误不会被吞成空数组")
    func propagatesRepositoryFailure() async {
        let catalog = LocalAmbientCatalog(loadStarred: { throw StubError.unavailable })

        do {
            _ = try await catalog.loadCards(scene: .owners)
            Issue.record("Expected repository failure")
        } catch {
            #expect(error is StubError)
        }
    }
}
