//
//  ScreensaverAvatarCache.swift
//  Starcat
//
//  主应用把 Owner 头像准备到屏保快照目录。.saver 不包含本文件，也不发起网络请求。
//

import AppKit
import Foundation

/// 为屏保快照准备本地头像文件，并按当前卡片集合 GC。
///
/// 关键约束：
/// - GitHub `s=512` 只缩小不放大，很多 Owner 原图只有几十到一百多 px；
/// - 能解码的图都留下，避免屏保格子永远停在字母；
/// - 已有短边 ≥ 200 的文件才跳过网络，不够大再尝试换更大的；
/// - 下载并发上限对齐 `AvatarCacheLoader`，避免上千 Owner 打爆 CDN。
struct ScreensaverAvatarCache: Sendable {
    typealias Downloader = @Sendable (URL) async -> Data?
    typealias LocalImageSource = @Sendable (URL) async -> Data?
    typealias ProgressHandler = @Sendable (Int, Int) -> Void
    typealias CheckpointHandler = @Sendable ([ScreensaverSnapshotCard]) -> Void

    private static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let requestedPixelSize = 512
    /// 短边达到这个值就视为够用，不再为同一 Owner 打 GitHub。
    static let minimumReusablePixelSize = 200
    /// 上千 Owner 必须并行；8 路与导出头像加载器同一档。
    private static let downloadConcurrency = 8

    let containerURL: URL

    private var directoryURL: URL {
        ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: containerURL)
    }

    init(containerURL: URL) {
        self.containerURL = containerURL
    }

    /// visualKey 映射为不可注入路径的稳定 PNG 文件名。
    static func fileName(visualKey: String) -> String {
        ScreensaverSharedConfiguration.avatarFileName(visualKey: visualKey)
    }

    func enrich(
        cards: [AmbientCardModel],
        downloader: @escaping Downloader,
        localImageSource: LocalImageSource? = nil,
        onProgress: ProgressHandler? = nil,
        onCheckpoint: CheckpointHandler? = nil
    ) async -> [ScreensaverSnapshotCard] {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        onProgress?(0, cards.count)
        guard !cards.isEmpty else {
            prune(keeping: [])
            return []
        }

        var results = [ScreensaverSnapshotCard?](repeating: nil, count: cards.count)
        await withTaskGroup(of: (Int, ScreensaverSnapshotCard).self) { group in
            var nextIndex = 0
            var running = 0
            let limit = min(Self.downloadConcurrency, cards.count)

            func enqueue() {
                while running < limit, nextIndex < cards.count {
                    let index = nextIndex
                    let card = cards[index]
                    nextIndex += 1
                    running += 1
                    group.addTask {
                        let snapshot = await self.materialize(
                            card,
                            downloader: downloader,
                            localImageSource: localImageSource
                        )
                        return (index, snapshot)
                    }
                }
            }

            enqueue()
            var completed = 0
            for await (index, snapshot) in group {
                results[index] = snapshot
                completed += 1
                onProgress?(completed, cards.count)
                if shouldCheckpoint(completed: completed, total: cards.count) {
                    onCheckpoint?(mergedCards(cards: cards, results: results))
                }
                running -= 1
                enqueue()
            }
        }

        let materialized = results.compactMap { $0 }
        prune(keeping: Set(materialized.compactMap(\.imageFileName)))
        return materialized
    }

    /// 第一张、每 32 张、以及全部完成时写回 JSON，屏保不用干等到下载结束。
    private func shouldCheckpoint(completed: Int, total: Int) -> Bool {
        completed == 1 || completed == total || completed.isMultiple(of: 32)
    }

    private func mergedCards(
        cards: [AmbientCardModel],
        results: [ScreensaverSnapshotCard?]
    ) -> [ScreensaverSnapshotCard] {
        cards.enumerated().map { index, card in
            results[index] ?? ScreensaverSnapshotCard(
                id: card.id,
                visualKey: card.visualKey,
                title: card.title,
                imageFileName: nil
            )
        }
    }

    private func materialize(
        _ card: AmbientCardModel,
        downloader: @escaping Downloader,
        localImageSource: LocalImageSource?
    ) async -> ScreensaverSnapshotCard {
        let fileName = Self.fileName(visualKey: card.visualKey)
        let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let existing = try? Data(contentsOf: destinationURL)
        var bestEdge = existing.flatMap(pixelEdge(of:)) ?? 0
        var storedFileName: String? = bestEdge > 0 ? fileName : nil

        // GitHub 的 s=512 只缩小、不放大。很多 Owner 原图只有 80…199px，
        // 丢掉它们屏保就会一直停在字母。已有能解码的图先留着，不够大再尝试换更大的。
        if bestEdge < Self.minimumReusablePixelSize,
           let remoteURL = allowedDownloadURL(from: card.artworkURLString) {
            if let local = await localImageSource?(remoteURL) {
                consider(local, destinationURL: destinationURL, fileName: fileName, bestEdge: &bestEdge, storedFileName: &storedFileName)
            }
            if bestEdge < Self.minimumReusablePixelSize,
               let data = await downloader(remoteURL) {
                consider(data, destinationURL: destinationURL, fileName: fileName, bestEdge: &bestEdge, storedFileName: &storedFileName)
            }
        }

        return ScreensaverSnapshotCard(
            id: card.id,
            visualKey: card.visualKey,
            title: card.title,
            imageFileName: storedFileName
        )
    }

    private func consider(
        _ data: Data,
        destinationURL: URL,
        fileName: String,
        bestEdge: inout Int,
        storedFileName: inout String?
    ) {
        guard data.count <= Self.maximumResponseBytes,
              let png = pngData(from: data),
              let edge = pixelEdge(of: png),
              edge > bestEdge else {
            return
        }
        guard writeReusablePNG(png, to: destinationURL, fileName: fileName) != nil else { return }
        bestEdge = edge
        storedFileName = fileName
    }

    func clear() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func allowedDownloadURL(from rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let host = url.host?.lowercased(),
              host == "github.com" || host == "avatars.githubusercontent.com" else {
            return nil
        }
        // 与 App 内 RemoteAvatar 同一套 size / s 规则，避免列表 80px 的 cache key 被误当成屏保图。
        return GitHubAvatarURL.imageURL(
            from: rawValue,
            displayDiameter: CGFloat(Self.requestedPixelSize),
            displayScale: 1,
            minimumPixelSize: Self.requestedPixelSize,
            maximumPixelSize: Self.requestedPixelSize
        ) ?? url
    }

    private func pixelEdge(of data: Data) -> Int? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return min(bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    private func pngData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func writeReusablePNG(_ png: Data, to destinationURL: URL, fileName: String) -> String? {
        do {
            try atomicWrite(png, to: destinationURL)
            return fileName
        } catch {
            return nil
        }
    }

    private func atomicWrite(_ data: Data, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [])
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func prune(keeping retainedFileNames: Set<String>) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in urls where !retainedFileNames.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }
}
