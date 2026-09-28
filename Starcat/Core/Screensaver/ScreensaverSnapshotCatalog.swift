//
//  ScreensaverSnapshotCatalog.swift
//  Starcat
//
//  把 App Group 快照投影为 Ambient 卡片。屏保进程只走这条只读路径。
//

import Foundation

/// 从本地快照提供 Owner 卡片；缺图时保留 title 仅供占位首字母使用。
struct ScreensaverSnapshotCatalog: AmbientCatalogProviding {
    let store: ScreensaverSnapshotStore

    init(store: ScreensaverSnapshotStore) {
        self.store = store
    }

    func loadCards(scene: AmbientSceneKind) async throws -> [AmbientCardModel] {
        let snapshot = try store.load()
        let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(
            containerURL: store.containerURL
        )
        return snapshot.cards.map { card in
            let artworkURLString = resolvedArtworkURLString(
                imageFileName: card.imageFileName,
                visualKey: card.visualKey,
                avatarsDirectory: avatars
            )
            return AmbientCardModel(
                id: card.id,
                visualKey: card.visualKey,
                title: card.title,
                artworkURLString: artworkURLString,
                subtitle: nil,
                metadata: [:]
            )
        }
    }

    private func resolvedArtworkURLString(
        imageFileName: String?,
        visualKey: String,
        avatarsDirectory: URL
    ) -> String? {
        let candidates = [
            imageFileName,
            ScreensaverSharedConfiguration.avatarFileName(visualKey: visualKey)
        ]
        for candidate in candidates {
            guard let candidate,
                  !candidate.isEmpty,
                  !candidate.contains("/"),
                  !candidate.contains("..") else {
                continue
            }
            let url = avatarsDirectory.appendingPathComponent(candidate, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return url.absoluteString
        }
        return nil
    }
}

/// 屏保只关心格子上的图。title 变化不应触发整墙重绘。
enum ScreensaverArtworkSignature {
    static func make(_ cards: [AmbientCardModel]) -> Int {
        var hasher = Hasher()
        hasher.combine(cards.count)
        for card in cards {
            hasher.combine(card.id)
            hasher.combine(card.artworkURLString)
        }
        return hasher.finalize()
    }
}
