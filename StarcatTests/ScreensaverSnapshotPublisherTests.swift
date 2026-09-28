//
//  ScreensaverSnapshotPublisherTests.swift
//  StarcatTests
//
//  屏保快照发布、头像落盘和 Catalog 只读投影。下载器全部注入，不发真实网络请求。
//

import AppKit
import Foundation
import Testing
@testable import Starcat

@Suite("Screensaver snapshot pipeline")
struct ScreensaverSnapshotPublisherTests {

    @Test("visualKey 使用稳定哈希文件名且拒绝路径字符")
    func createsStableSafeFileName() {
        let first = ScreensaverAvatarCache.fileName(visualKey: "owner:Apple")
        let second = ScreensaverAvatarCache.fileName(visualKey: "owner:Apple")
        let hostile = ScreensaverAvatarCache.fileName(visualKey: "../escape")

        #expect(first == second)
        #expect(first.hasSuffix(".png"))
        #expect(!hostile.contains("/"))
        #expect(!hostile.contains(".."))
    }

    @Test("多个缺失头像会并发下载，而不是一个接一个排队")
    func downloadsMissingAvatarsConcurrently() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let peak = PeakCounter()
            let cards = (0..<4).map { index in
                makeCard(
                    id: "owner:user\(index)",
                    visualKey: "owner:user\(index)",
                    title: "user\(index)"
                )
            }

            let results = await cache.enrich(
                cards: cards,
                downloader: { url in
                    await peak.enter()
                    try? await Task.sleep(for: .milliseconds(80))
                    await peak.leave()
                    _ = url
                    return pngData(dimension: 512)
                }
            )

            #expect(results.count == 4)
            #expect(results.allSatisfy { $0.imageFileName != nil })
            #expect(await peak.peak >= 2)
        }
    }

    @Test("已有高分辨率头像会被复用，且未引用文件会被 GC")
    func reusesHighResolutionCachedAvatarAndPrunesExtras() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let visualKey = "owner:apple"
            let fileName = ScreensaverAvatarCache.fileName(visualKey: visualKey)
            let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: directory)
            try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
            try pngData(dimension: 512).write(to: avatars.appendingPathComponent(fileName))
            try Data([0x00]).write(to: avatars.appendingPathComponent("stale.png"))

            let downloader = CountingDownloader()
            let cards = await cache.enrich(
                cards: [makeCard(id: "owner:apple", visualKey: visualKey, title: "apple")],
                downloader: { url in
                    await downloader.record(url)
                    return nil
                }
            )

            #expect(await downloader.count == 0)
            #expect(cards.first?.imageFileName == fileName)
            #expect(FileManager.default.fileExists(atPath: avatars.appendingPathComponent("stale.png").path) == false)
        }
    }

    @Test("低分辨率本地文件不能复用，必须重新下载够大的图")
    func rejectsLowResolutionCachedAvatar() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let visualKey = "owner:apple"
            let fileName = ScreensaverAvatarCache.fileName(visualKey: visualKey)
            let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: directory)
            try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
            try pngData(dimension: 64).write(to: avatars.appendingPathComponent(fileName))

            let downloader = CountingDownloader()
            let cards = await cache.enrich(
                cards: [makeCard(id: "owner:apple", visualKey: visualKey, title: "apple")],
                downloader: { url in
                    await downloader.record(url)
                    return pngData(dimension: 512)
                }
            )

            #expect(await downloader.count == 1)
            #expect(cards.first?.imageFileName == fileName)
            #expect(pixelEdge(at: avatars.appendingPathComponent(fileName)) >= 512)
        }
    }

    @Test("GitHub 不放大原图时仍保留能解码的头像，不要改画字母")
    func keepsDecodableAvatarWhenCDNDoesNotUpscale() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let visualKey = "owner:small"
            let fileName = ScreensaverAvatarCache.fileName(visualKey: visualKey)
            let cards = await cache.enrich(
                cards: [makeCard(id: "owner:small", visualKey: visualKey, title: "small")],
                downloader: { _ in pngData(dimension: 80) }
            )

            #expect(cards.first?.imageFileName == fileName)
            #expect(
                FileManager.default.fileExists(
                    atPath: ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: directory)
                        .appendingPathComponent(fileName).path
                )
            )
        }
    }

    @Test("下载失败时保留已经能显示的小头像，不要 prune 掉")
    func keepsExistingDecodableAvatarWhenDownloadFails() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let visualKey = "owner:small"
            let fileName = ScreensaverAvatarCache.fileName(visualKey: visualKey)
            let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: directory)
            try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
            try pngData(dimension: 80).write(to: avatars.appendingPathComponent(fileName))

            let cards = await cache.enrich(
                cards: [makeCard(id: "owner:small", visualKey: visualKey, title: "small")],
                downloader: { _ in nil }
            )

            #expect(cards.first?.imageFileName == fileName)
            #expect(FileManager.default.fileExists(atPath: avatars.appendingPathComponent(fileName).path))
        }
    }

    @Test("高分辨率旁路缓存命中时不走网络")
    func reusesHighResolutionLocalLookup() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let downloader = CountingDownloader()
            let cards = await cache.enrich(
                cards: [makeCard(id: "owner:apple", visualKey: "owner:apple", title: "apple")],
                downloader: { url in
                    await downloader.record(url)
                    return nil
                },
                localImageSource: { _ in pngData(dimension: 512) }
            )

            #expect(await downloader.count == 0)
            #expect(cards.first?.imageFileName != nil)
        }
    }

    @Test("低分辨率旁路缓存不能当屏保图用")
    func ignoresLowResolutionLocalLookup() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let downloader = CountingDownloader()
            let cards = await cache.enrich(
                cards: [makeCard(id: "owner:apple", visualKey: "owner:apple", title: "apple")],
                downloader: { url in
                    await downloader.record(url)
                    return pngData(dimension: 512)
                },
                localImageSource: { _ in pngData(dimension: 80) }
            )

            #expect(await downloader.count == 1)
            #expect(cards.first?.imageFileName != nil)
        }
    }

    @Test("avatars.githubusercontent.com 用 s= 请求 512，不用列表那档尺寸")
    func requestsHighResolutionGitHubAvatarQuery() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let recorded = URLRecorder()
            _ = await cache.enrich(
                cards: [
                    AmbientCardModel(
                        id: "owner:apple",
                        visualKey: "owner:apple",
                        title: "apple",
                        artworkURLString: "https://avatars.githubusercontent.com/u/1?v=4",
                        subtitle: nil,
                        metadata: [:]
                    )
                ],
                downloader: { url in
                    await recorded.record(url)
                    return pngData(dimension: 512)
                }
            )
            let url = try #require(await recorded.url)
            #expect(url.host == "avatars.githubusercontent.com")
            #expect(url.query?.contains("s=512") == true)
            #expect(url.query?.contains("size=") == false)
        }
    }

    @Test("准备头像时按完成数上报进度")
    func reportsProgressForEveryCard() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let cards = (0..<3).map { index in
                makeCard(
                    id: "owner:user\(index)",
                    visualKey: "owner:user\(index)",
                    title: "user\(index)"
                )
            }
            let progress = ProgressRecorder()
            _ = await cache.enrich(
                cards: cards,
                downloader: { _ in pngData(dimension: 512) },
                onProgress: { completed, total in
                    progress.record(completed: completed, total: total)
                }
            )

            let events = progress.events
            #expect(events.contains { $0 == (0, 3) })
            #expect(events.last?.completed == 3)
            #expect(events.last?.total == 3)
            #expect(events.map(\.total).allSatisfy { $0 == 3 })
        }
    }

    @Test("Publisher 写入 userID 快照，Catalog 把本地文件投影为 file URL")
    func publishesSnapshotAndCatalogResolvesLocalFiles() async throws {
        try await withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let visualKey = "owner:apple"
            let fileName = ScreensaverAvatarCache.fileName(visualKey: visualKey)
            let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: directory)
            try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
            try pngData(dimension: 512).write(to: avatars.appendingPathComponent(fileName))

            let publisher = ScreensaverSnapshotPublisher(
                loadCards: {
                    [makeCard(id: "owner:apple", visualKey: visualKey, title: "apple")]
                },
                store: store,
                cache: cache,
                downloader: { _ in nil },
                now: { Date(timeIntervalSince1970: 1_758_096_000) }
            )

            try await publisher.publish(userID: 99)
            let snapshot = try store.load()
            #expect(snapshot.userID == 99)
            #expect(snapshot.cards.first?.imageFileName == fileName)

            let catalog = ScreensaverSnapshotCatalog(store: store)
            let cards = try await catalog.loadCards(scene: .owners)
            let card = try #require(cards.first)
            #expect(card.id == "owner:apple")
            #expect(card.title == "apple")
            #expect(card.artworkURLString?.hasPrefix("file:") == true)
            #expect(card.artworkURLString?.hasSuffix(fileName) == true)
        }
    }

    @Test("JSON 还没记下文件名时，Catalog 仍按 visualKey 认磁盘头像")
    func catalogResolvesExistingFileWhenImageFileNameMissing() async throws {
        try await withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            let visualKey = "owner:apple"
            let fileName = ScreensaverAvatarCache.fileName(visualKey: visualKey)
            let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: directory)
            try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
            try pngData(dimension: 256).write(to: avatars.appendingPathComponent(fileName))
            try store.save(
                ScreensaverSnapshot(
                    userID: 1,
                    cards: [
                        ScreensaverSnapshotCard(
                            id: "owner:apple",
                            visualKey: visualKey,
                            title: "apple",
                            imageFileName: nil
                        )
                    ]
                )
            )

            let cards = try await ScreensaverSnapshotCatalog(store: store).loadCards(scene: .owners)
            let card = try #require(cards.first)
            #expect(card.artworkURLString?.hasPrefix("file:") == true)
            #expect(card.artworkURLString?.hasSuffix(fileName) == true)
        }
    }

    @Test("Catalog 忽略含路径的文件名，缺图卡片仍保留 title")
    func catalogIgnoresUnsafeFileNames() async throws {
        try await withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            try store.save(
                ScreensaverSnapshot(
                    userID: 1,
                    cards: [
                        ScreensaverSnapshotCard(
                            id: "owner:evil",
                            visualKey: "owner:evil",
                            title: "evil",
                            imageFileName: "../escape.png"
                        )
                    ]
                )
            )
            let cards = try await ScreensaverSnapshotCatalog(store: store).loadCards(scene: .owners)
            #expect(cards.first?.title == "evil")
            #expect(cards.first?.artworkURLString == nil)
        }
    }

    @Test("头像下载完成前先写入占位快照，避免屏保一直停在空态")
    func writesPlaceholderSnapshotBeforeDownloadsFinish() async throws {
        try await withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let gate = DownloadGate()
            let publisher = ScreensaverSnapshotPublisher(
                loadCards: {
                    [makeCard(id: "owner:apple", visualKey: "owner:apple", title: "apple")]
                },
                store: store,
                cache: cache,
                downloader: { _ in
                    await gate.wait()
                    return pngData(dimension: 512)
                }
            )

            let task = Task {
                try await publisher.publish(userID: 7)
            }
            var snapshot: ScreensaverSnapshot?
            for _ in 0..<50 {
                if let loaded = try? store.load() {
                    snapshot = loaded
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let loaded = try #require(snapshot)
            #expect(loaded.userID == 7)
            #expect(loaded.cards.count == 1)
            #expect(loaded.cards.first?.title == "apple")

            await gate.release()
            try await task.value
            #expect(try store.load().cards.first?.imageFileName != nil)
        }
    }

    @Test("部分头像就绪时就会写回 JSON，不用等全部下完")
    func checkpointsSnapshotBeforeAllDownloadsFinish() async throws {
        try await withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let gate = DownloadGate()
            let publisher = ScreensaverSnapshotPublisher(
                loadCards: {
                    [
                        makeCard(
                            id: "owner:ready",
                            visualKey: "owner:ready",
                            title: "ready",
                            artworkURLString: "https://github.com/ready.png"
                        ),
                        makeCard(
                            id: "owner:late",
                            visualKey: "owner:late",
                            title: "late",
                            artworkURLString: "https://github.com/late.png"
                        )
                    ]
                },
                store: store,
                cache: cache,
                downloader: { url in
                    if url.absoluteString.contains("late") {
                        await gate.wait()
                    }
                    return pngData(dimension: 256)
                }
            )

            let task = Task {
                try await publisher.publish(userID: 8)
            }
            var namedCount = 0
            for _ in 0..<50 {
                namedCount = (try? store.load().cards.filter { $0.imageFileName != nil }.count) ?? 0
                if namedCount == 1 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(namedCount == 1)

            await gate.release()
            try await task.value
            #expect(try store.load().cards.filter { $0.imageFileName != nil }.count == 2)
        }
    }

    @Test("增量 checkpoint 不得把已有头像文件名抹成 nil")
    func checkpointKeepsPreviousImageFileNames() async throws {
        try await withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let gate = DownloadGate()
            let lateKey = "owner:late"
            let lateName = ScreensaverAvatarCache.fileName(visualKey: lateKey)
            let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: directory)
            try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
            try pngData(dimension: 80).write(to: avatars.appendingPathComponent(lateName))
            try store.save(
                ScreensaverSnapshot(
                    userID: 8,
                    cards: [
                        ScreensaverSnapshotCard(
                            id: "owner:ready",
                            visualKey: "owner:ready",
                            title: "ready",
                            imageFileName: nil
                        ),
                        ScreensaverSnapshotCard(
                            id: "owner:late",
                            visualKey: lateKey,
                            title: "late",
                            imageFileName: lateName
                        )
                    ]
                )
            )

            let publisher = ScreensaverSnapshotPublisher(
                loadCards: {
                    [
                        makeCard(
                            id: "owner:ready",
                            visualKey: "owner:ready",
                            title: "ready",
                            artworkURLString: "https://github.com/ready.png"
                        ),
                        makeCard(
                            id: "owner:late",
                            visualKey: lateKey,
                            title: "late",
                            artworkURLString: "https://github.com/late.png"
                        )
                    ]
                },
                store: store,
                cache: cache,
                downloader: { url in
                    if url.absoluteString.contains("late") {
                        await gate.wait()
                    }
                    return pngData(dimension: 512)
                }
            )

            let task = Task {
                try await publisher.publish(userID: 8)
            }
            var lateNameStillPresent = false
            for _ in 0..<50 {
                let cards = (try? store.load().cards) ?? []
                let readyNamed = cards.contains { $0.id == "owner:ready" && $0.imageFileName != nil }
                let lateNamed = cards.contains { $0.id == "owner:late" && $0.imageFileName == lateName }
                if readyNamed && lateNamed {
                    lateNameStillPresent = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(lateNameStillPresent)

            await gate.release()
            try await task.value
        }
    }

    @Test("clear 删除快照后 Catalog 映射为缺文件")
    func clearRemovesSnapshot() async throws {
        try await withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            let publisher = ScreensaverSnapshotPublisher(
                loadCards: { [] },
                store: store,
                cache: ScreensaverAvatarCache(containerURL: directory),
                downloader: { _ in nil }
            )
            try await publisher.publish(userID: 1)
            try publisher.clear()
            #expect(throws: ScreensaverSnapshotStoreError.snapshotMissing) {
                try store.load()
            }
        }
    }

    /// 卡住下载器，用来断言 enrich 完成前 JSON 已经落盘。
    private actor DownloadGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor CountingDownloader {
        private(set) var count = 0

        func record(_ url: URL) {
            count += 1
            _ = url
        }
    }

    /// 记录同时进行的下载数，用来锁住「必须并发」而不是靠易碎的耗时断言。
    private actor PeakCounter {
        private var current = 0
        private(set) var peak = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func leave() {
            current = max(0, current - 1)
        }
    }

    private actor URLRecorder {
        private(set) var url: URL?

        func record(_ url: URL) {
            self.url = url
        }
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(completed: Int, total: Int)] = []

        var events: [(completed: Int, total: Int)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func record(completed: Int, total: Int) {
            lock.lock()
            defer { lock.unlock() }
            storage.append((completed, total))
        }
    }

    private func makeCard(
        id: String,
        visualKey: String,
        title: String,
        artworkURLString: String = "https://github.com/apple.png"
    ) -> AmbientCardModel {
        AmbientCardModel(
            id: id,
            visualKey: visualKey,
            title: title,
            artworkURLString: artworkURLString,
            subtitle: nil,
            metadata: [:]
        )
    }

    private func pngData(dimension: Int) -> Data {
        let size = NSSize(width: dimension, height: dimension)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let bitmap = NSBitmapImageRep(data: tiff)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func pixelEdge(at url: URL) -> Int {
        let data = try! Data(contentsOf: url)
        let image = NSImage(data: data)!
        let tiff = image.tiffRepresentation!
        let bitmap = NSBitmapImageRep(data: tiff)!
        return min(bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-screensaver-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
