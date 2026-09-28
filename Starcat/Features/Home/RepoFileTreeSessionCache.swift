//
//  RepoFileTreeSessionCache.swift
//  Starcat
//
//  文件树的进程内缓存。只存 Git Trees 响应，不存预览内容和勾选。
//
//  Sheet 每次打开都会 new 一个 ViewModel，没有这层缓存就会反复打 recursive tree。
//  树能从 GitHub 重建，不落库、不迁 schema；用户点刷新才重新拉。
//  key 带 ref：切分支互不影响。
//

import Foundation

actor RepoFileTreeSessionCache {
    static let shared = RepoFileTreeSessionCache()

    private var trees: [String: GitHubGitTreeDTO] = [:]

    func tree(owner: String, repo: String, ref: String) -> GitHubGitTreeDTO? {
        trees[Self.key(owner: owner, repo: repo, ref: ref)]
    }

    func store(_ dto: GitHubGitTreeDTO, owner: String, repo: String, ref: String) {
        trees[Self.key(owner: owner, repo: repo, ref: ref)] = dto
    }

    static func key(owner: String, repo: String, ref: String) -> String {
        "\(owner)/\(repo)#\(ref)"
    }
}
