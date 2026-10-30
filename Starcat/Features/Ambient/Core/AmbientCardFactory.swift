//
//  AmbientCardFactory.swift
//  Starcat
//
//  把数据库 Repo 快照聚合成 Owner 卡片，供屏保快照发布。Factory 不读取数据库、不做 I/O，
//  并统一归一化 owner visualKey，避免同一人头像重复进墙。
//

import Foundation

/// Factory 的稳定输入。屏保只消费 owner 与头像，仓库名不再进格子。
struct AmbientRepoSeed: Equatable, Sendable {
    let owner: String
    let ownerAvatarURL: String?

    init(repo: Repo) {
        owner = repo.owner
        ownerAvatarURL = repo.ownerAvatar
    }
}

/// Owner 卡片的纯值工厂。仓库格子只存在于已删除的 Debug 全屏窗口。
enum AmbientCardFactory {
    static func cards(from repos: [Repo], scene: AmbientSceneKind) -> [AmbientCardModel] {
        cards(from: repos.map(AmbientRepoSeed.init), scene: scene)
    }

    static func cards(from seeds: [AmbientRepoSeed], scene: AmbientSceneKind) -> [AmbientCardModel] {
        switch scene {
        case .owners:
            ownerCards(from: seeds)
        }
    }

    private static func ownerCards(from seeds: [AmbientRepoSeed]) -> [AmbientCardModel] {
        struct OwnerAccumulator {
            let displayName: String
            var explicitAvatarURL: String?
        }

        var order: [String] = []
        var owners: [String: OwnerAccumulator] = [:]

        for seed in seeds {
            let key = normalizeOwner(seed.owner)
            guard !key.isEmpty else { continue }
            let explicitAvatar = normalizedNonempty(seed.ownerAvatarURL)

            if var existing = owners[key] {
                // 同一 owner 的旧 Repo 可能没有 avatar；后续快照有真实 URL 时应补齐，
                // 但展示 casing 始终保留第一次有效值，避免列表随同步顺序抖动。
                if existing.explicitAvatarURL == nil {
                    existing.explicitAvatarURL = explicitAvatar
                    owners[key] = existing
                }
            } else {
                order.append(key)
                owners[key] = OwnerAccumulator(
                    displayName: seed.owner.trimmingCharacters(in: .whitespacesAndNewlines),
                    explicitAvatarURL: explicitAvatar
                )
            }
        }

        return order.compactMap { key in
            guard let owner = owners[key] else { return nil }
            return AmbientCardModel(
                id: "owner:\(key)",
                visualKey: "owner:\(key)",
                title: owner.displayName,
                artworkURLString: preferredAvatar(explicit: owner.explicitAvatarURL, owner: owner.displayName),
                subtitle: nil,
                metadata: [:]
            )
        }
    }

    private static func normalizeOwner(_ owner: String) -> String {
        owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func preferredAvatar(explicit: String?, owner: String) -> String? {
        if let explicit = normalizedNonempty(explicit) {
            return explicit
        }
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedOwner.isEmpty ? nil : RepoAvatarURL.from(owner: normalizedOwner)
    }

    private static func normalizedNonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
