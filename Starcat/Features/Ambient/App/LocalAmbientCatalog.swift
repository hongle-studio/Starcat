//
//  LocalAmbientCatalog.swift
//  Starcat
//
//  屏保发布用的本地目录。它只通过注入的 RepoRepositoryProtocol 获取一次 Star 快照，
//  不直接接触 Database.shared，读取错误原样交给发布方。
//

/// 从当前用户的本地 Star 快照生成 Ambient 卡片。
struct LocalAmbientCatalog: AmbientCatalogProviding {
    typealias LoadStarred = @Sendable () async throws -> [Repo]

    private let loadStarred: LoadStarred

    init(repository: any RepoRepositoryProtocol) {
        loadStarred = {
            try await repository.fetchAllStarred()
        }
    }

    /// 测试边界：只替换 repository 的单个读取动作，避免为一个查询伪造整套大协议。
    init(loadStarred: @escaping LoadStarred) {
        self.loadStarred = loadStarred
    }

    func loadCards(scene: AmbientSceneKind) async throws -> [AmbientCardModel] {
        let repos = try await loadStarred()
        return AmbientCardFactory.cards(from: repos, scene: scene)
    }
}
