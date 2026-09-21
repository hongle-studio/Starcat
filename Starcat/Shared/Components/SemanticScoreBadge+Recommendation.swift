//
//  SemanticScoreBadge+Recommendation.swift
//  Starcat
//
//  推荐场景的 SemanticScoreBadge 轻量化入口。
//
//  背景：完整 init 要求 `SemanticSearchHit{repo, score, displayScore, tier, reason}`，
//  其中 `repo` 字段是 GRDB 持久化的领域模型（22+ 必填字段），推荐接口只返回
//  `RepoRecommendationItem{repoID, fullName, ...}`，合成完整 Repo 字段会污染无关数据。
//
//  本扩展提供 `SemanticSearchHit.displayOnly` 与 `SemanticScoreBadge(score:reason:)`：
//  内部合成最小可用 SemanticSearchHit（Repo 字段填空，body 只读 displayScore / tier / reason）；
//  tier 按原 SemanticSearchService 的阈值映射（≥0.85→4 / ≥0.65→3 / ≥0.45→2 / 其余→1）。
//
//  视觉上与完整 init 完全一致，复用同一份 body 代码（紫胶囊 + 星星 + 百分比）。
//

import Foundation

extension SemanticSearchHit {
    /// 只为分数徽章构造命中：Search Center / 推荐卡片没有完整 `Repo` 时使用。
    ///
    /// body 只读 `displayScore` / `tier` / `reason`，placeholder Repo 不会进 UI。
    static func displayOnly(score: Double, reason: String) -> SemanticSearchHit {
        let clampedScore = max(0, min(1, score))

        // tier 阈值与 SemanticSearchService.displayScore → tier 映射保持一致。
        // 这里不复用 service 内部逻辑（service 是 @MainActor + 依赖注入），重写一遍短。
        let tier: Int
        switch clampedScore {
        case 0.85...: tier = 4
        case 0.65..<0.85: tier = 3
        case 0.45..<0.65: tier = 2
        default: tier = 1
        }

        let placeholderRepo = Repo(
            id: 0,
            owner: "",
            name: "",
            fullName: "",
            description: nil,
            language: nil,
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )

        return SemanticSearchHit(
            repo: placeholderRepo,
            score: score,
            displayScore: clampedScore,
            tier: tier,
            reason: reason
        )
    }
}

extension SemanticScoreBadge {

    /// 简化初始化：从一个 Double 分数直接构造（推荐场景使用）。
    ///
    /// - Parameters:
    ///   - score: 0-1 区间的匹配度分数；超出范围会被 clamp
    ///   - reason: hover tooltip 文案（建议传「推荐理由」一句话）
    init(score: Double, reason: String) {
        self.init(hit: .displayOnly(score: score, reason: reason))
    }
}
