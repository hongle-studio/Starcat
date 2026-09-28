//
//  ScreensaverSnapshotStoreTests.swift
//  StarcatTests
//
//  Direct 屏保 App Group 快照契约测试。只用临时目录，不碰真实 App Group。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ScreensaverSnapshotStore")
struct ScreensaverSnapshotStoreTests {

    @Test("ready 快照可以按 v1 契约往返编码")
    func roundTripsReadySnapshot() throws {
        try withTemporaryDirectory { directory in
            let generatedAt = Date(timeIntervalSince1970: 1_758_096_000)
            let snapshot = ScreensaverSnapshot(
                generatedAt: generatedAt,
                userID: 42,
                cards: [
                    ScreensaverSnapshotCard(
                        id: "owner:apple",
                        visualKey: "owner:apple",
                        title: "apple",
                        imageFileName: "abc.png"
                    )
                ]
            )
            let store = ScreensaverSnapshotStore(containerURL: directory)

            try store.save(snapshot)

            #expect(try store.load() == snapshot)
        }
    }

    @Test("缺文件、坏 JSON 和不支持的 schema 分别映射稳定错误")
    func mapsLoadFailures() throws {
        try withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)

            #expect(throws: ScreensaverSnapshotStoreError.snapshotMissing) {
                try store.load()
            }

            let snapshotURL = ScreensaverSharedConfiguration.snapshotURL(containerURL: directory)
            try Data("{not-json".utf8).write(to: snapshotURL)
            #expect(throws: ScreensaverSnapshotStoreError.corruptedSnapshot) {
                try store.load()
            }
        }

        try withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            try store.save(
                ScreensaverSnapshot(
                    schemaVersion: ScreensaverSnapshot.currentSchemaVersion + 1,
                    generatedAt: Date(timeIntervalSince1970: 0),
                    userID: 1,
                    cards: []
                )
            )
            #expect(
                throws: ScreensaverSnapshotStoreError.unsupportedSchemaVersion(
                    ScreensaverSnapshot.currentSchemaVersion + 1
                )
            ) {
                try store.load()
            }
        }
    }

    @Test("连续原子替换后只保留正式快照且无临时文件")
    func atomicallyReplacesSnapshotWithoutTemporaryFiles() throws {
        try withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            try store.save(ScreensaverSnapshot(userID: 1, cards: []))
            try store.save(
                ScreensaverSnapshot(
                    userID: 2,
                    cards: [
                        ScreensaverSnapshotCard(
                            id: "owner:apple",
                            visualKey: "owner:apple",
                            title: "apple",
                            imageFileName: nil
                        )
                    ]
                )
            )

            #expect(try store.load().userID == 2)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names == [ScreensaverSharedConfiguration.snapshotFileName])
        }
    }

    @Test("删除快照会清掉 manifest 和 avatars 子目录，并保留容器其它文件")
    func deleteRemovesManifestAndAvatarsOnly() throws {
        try withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            try store.save(ScreensaverSnapshot(userID: 1, cards: []))
            let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: directory)
            try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
            try Data([0x01]).write(to: avatars.appendingPathComponent("keep-me.png"))
            let sibling = directory.appendingPathComponent("other.txt")
            try Data("hello".utf8).write(to: sibling)

            try store.delete()

            #expect(throws: ScreensaverSnapshotStoreError.snapshotMissing) {
                try store.load()
            }
            #expect(FileManager.default.fileExists(atPath: avatars.path) == false)
            #expect(FileManager.default.fileExists(atPath: sibling.path))
        }
    }

    @Test("生产容器路径落在 Application Support 下的 screensaver 目录")
    func productionContainerUsesApplicationSupport() {
        let url = ScreensaverSharedConfiguration.productionContainerURL()
        #expect(url.path.contains("/Library/Application Support/com.starcat.app/screensaver"))
        #expect(!url.path.contains("/Library/Containers/"))
        #expect(
            ScreensaverSharedConfiguration.snapshotURL(containerURL: url).lastPathComponent
                == ScreensaverSharedConfiguration.snapshotFileName
        )
    }

    @Test("生产容器路径使用注入的家目录，而不是 FileManager 的沙箱家目录")
    func productionContainerUsesInjectedHomeDirectory() {
        let home = URL(fileURLWithPath: "/tmp/starcat-fake-home", isDirectory: true)
        let url = ScreensaverSharedConfiguration.productionContainerURL(homeDirectory: home)
        #expect(
            url.path
                == "/tmp/starcat-fake-home/Library/Application Support/com.starcat.app/screensaver"
        )
    }

    @Test("缺文件时 revision 稳定，写入后才会变化")
    func revisionChangesOnlyAfterSave() throws {
        try withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            let missing = store.revision()
            #expect(missing.exists == false)
            #expect(store.revision() == missing)

            try store.save(ScreensaverSnapshot(userID: 1, cards: []))
            let first = store.revision()
            #expect(first.exists)
            #expect(first.fileSize > 0)
            #expect(first != missing)
            #expect(store.revision() == first)

            try store.save(ScreensaverSnapshot(userID: 2, cards: []))
            let second = store.revision()
            #expect(second.exists)
            #expect(second != first)
        }
    }

    @Test("artwork signature 只在 id 或图片 URL 变化时改变")
    func artworkSignatureIgnoresUnrelatedIdentity() {
        let first = AmbientCardModel(
            id: "owner:a",
            visualKey: "owner:a",
            title: "A",
            artworkURLString: "file:///tmp/a.png",
            subtitle: nil,
            metadata: [:]
        )
        let renamed = AmbientCardModel(
            id: "owner:a",
            visualKey: "owner:a",
            title: "Alpha",
            artworkURLString: "file:///tmp/a.png",
            subtitle: nil,
            metadata: [:]
        )
        let newImage = AmbientCardModel(
            id: "owner:a",
            visualKey: "owner:a",
            title: "A",
            artworkURLString: "file:///tmp/b.png",
            subtitle: nil,
            metadata: [:]
        )

        #expect(ScreensaverArtworkSignature.make([first]) == ScreensaverArtworkSignature.make([renamed]))
        #expect(ScreensaverArtworkSignature.make([first]) != ScreensaverArtworkSignature.make([newImage]))
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-screensaver-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
