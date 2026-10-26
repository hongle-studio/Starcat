//
//  GitHubStarListAIApplicationProgress.swift
//  Starcat
//
//  分组应用批次的轻量展示进度，不保存选择、不参与请求调度。
//

/// 按仓库而非分组关联或接口调用计数；分母在应用开始时冻结，不随选择被移除而缩小。
struct GitHubStarListAIApplicationProgress: Equatable, Sendable {
    let processedRepositoryCount: Int
    let totalRepositoryCount: Int
}
