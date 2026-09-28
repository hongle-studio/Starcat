//
//  ScreensaverSnapshotPublisher.swift
//  Starcat
//
//  从当前账号 stars 拍 Owner 快照并写入屏保目录。发布必须带 userID。
//  登出由调用方 clear；已登录账号的冷启动不要先删快照，否则屏保会先空一截。
//

import Foundation

/// 把 Ambient Owner 目录写成屏保可消费的本地快照。
struct ScreensaverSnapshotPublisher {
    typealias LoadCards = () async throws -> [AmbientCardModel]
    typealias Clock = @Sendable () -> Date

    private let loadCards: LoadCards
    private let store: ScreensaverSnapshotStore
    private let cache: ScreensaverAvatarCache
    private let downloader: ScreensaverAvatarCache.Downloader
    private let localImageSource: ScreensaverAvatarCache.LocalImageSource
    private let now: Clock

    init(
        loadCards: @escaping LoadCards,
        store: ScreensaverSnapshotStore,
        cache: ScreensaverAvatarCache,
        downloader: @escaping ScreensaverAvatarCache.Downloader,
        localImageSource: @escaping ScreensaverAvatarCache.LocalImageSource = { _ in nil },
        now: @escaping Clock = Date.init
    ) {
        self.loadCards = loadCards
        self.store = store
        self.cache = cache
        self.downloader = downloader
        self.localImageSource = localImageSource
        self.now = now
    }

    func publish(
        userID: Int64,
        onProgress: ScreensaverAvatarCache.ProgressHandler? = nil
    ) async throws {
        let cards = try await loadCards()
        onProgress?(0, cards.count)
        // 头像下载可能要几分钟。先把卡片名单落盘，屏保至少能画占位色块，
        // 而不是一直停在空态图标。已有快照则保留旧图，等 enrich 原子覆盖。
        if (try? store.load()) == nil {
            try store.save(
                ScreensaverSnapshot(
                    generatedAt: now(),
                    userID: userID,
                    cards: cards.map { card in
                        ScreensaverSnapshotCard(
                            id: card.id,
                            visualKey: card.visualKey,
                            title: card.title,
                            imageFileName: nil
                        )
                    }
                )
            )
        }
        let snapshotStore = store
        let clock = now
        let snapshotCards = await cache.enrich(
            cards: cards,
            downloader: downloader,
            localImageSource: localImageSource,
            onProgress: onProgress,
            onCheckpoint: { checkpointCards in
                try? snapshotStore.save(
                    ScreensaverSnapshot(
                        generatedAt: clock(),
                        userID: userID,
                        cards: Self.preservingExistingImageNames(
                            checkpointCards,
                            store: snapshotStore
                        )
                    )
                )
            }
        )
        try store.save(
            ScreensaverSnapshot(
                generatedAt: now(),
                userID: userID,
                cards: Self.preservingExistingImageNames(snapshotCards, store: store)
            )
        )
    }

    /// 增量写回时，未完成的卡片会暂时没有文件名；不能把上一轮已经落盘的头像抹掉。
    private static func preservingExistingImageNames(
        _ incoming: [ScreensaverSnapshotCard],
        store: ScreensaverSnapshotStore
    ) -> [ScreensaverSnapshotCard] {
        guard let previous = try? store.load() else { return incoming }
        let previousNames = Dictionary(
            uniqueKeysWithValues: previous.cards.compactMap { card -> (String, String)? in
                guard let name = card.imageFileName else { return nil }
                return (card.id, name)
            }
        )
        let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: store.containerURL)
        return incoming.map { card in
            if card.imageFileName != nil { return card }
            guard let oldName = previousNames[card.id],
                  !oldName.isEmpty,
                  !oldName.contains("/"),
                  !oldName.contains("..") else {
                return card
            }
            let url = avatars.appendingPathComponent(oldName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { return card }
            return ScreensaverSnapshotCard(
                id: card.id,
                visualKey: card.visualKey,
                title: card.title,
                imageFileName: oldName
            )
        }
    }

    func clear() throws {
        try store.delete()
    }

    static func makeNetworkDownloader() -> ScreensaverAvatarCache.Downloader {
        { url in
            if let data = await fetchOnce(url) {
                return data
            }
            return await fetchOnce(url)
        }
    }

    private static func fetchOnce(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("StarcatScreensaver/1", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  data.count <= 2 * 1_024 * 1_024 else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    /// 只复用 Kingfisher 里已经按屏保 URL（size/s=512）缓存、且像素够大的原图。
    static func makeLocalImageSource() -> ScreensaverAvatarCache.LocalImageSource {
        { url in
            AvatarCacheLoader.cachedImageData(for: url)
        }
    }
}
