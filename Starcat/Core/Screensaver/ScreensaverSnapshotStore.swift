//
//  ScreensaverSnapshotStore.swift
//  Starcat
//
//  版本化屏保快照的原子读写。写入先落同目录临时文件再 replace，
//  避免 legacyScreenSaver 读到半份 JSON。
//

import Foundation

/// 快照读取失败的稳定分类，供屏保映射为空态图标。
enum ScreensaverSnapshotStoreError: Error, Equatable, LocalizedError {
    case snapshotMissing
    case unsupportedSchemaVersion(Int)
    case corruptedSnapshot
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .snapshotMissing:
            return "Screensaver snapshot is missing"
        case .unsupportedSchemaVersion(let version):
            return "Unsupported Screensaver snapshot schema version: \(version)"
        case .corruptedSnapshot:
            return "Screensaver snapshot is corrupted"
        case .writeFailed:
            return "Screensaver snapshot could not be written"
        }
    }
}

/// 屏保用 mtime + size 判断快照有没有变，避免每两秒解码整份 JSON。
struct ScreensaverSnapshotRevision: Equatable, Sendable {
    let exists: Bool
    let fileSize: Int
    let modifiedAt: TimeInterval?
}

/// 对单一 App Group 容器执行屏保快照读写。
struct ScreensaverSnapshotStore: Sendable {
    let containerURL: URL

    private var snapshotURL: URL {
        ScreensaverSharedConfiguration.snapshotURL(containerURL: containerURL)
    }

    private var avatarsDirectoryURL: URL {
        ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: containerURL)
    }

    init(containerURL: URL) {
        self.containerURL = containerURL
    }

    /// 只 stat 快照文件。屏保空转时走这条路径，不要 `load()`。
    func revision() -> ScreensaverSnapshotRevision {
        let values = try? snapshotURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let exists = FileManager.default.fileExists(atPath: snapshotURL.path)
        return ScreensaverSnapshotRevision(
            exists: exists,
            fileSize: values?.fileSize ?? 0,
            modifiedAt: values?.contentModificationDate?.timeIntervalSinceReferenceDate
        )
    }

    /// 从磁盘读取并验证当前版本快照。
    func load() throws -> ScreensaverSnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: snapshotURL, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw ScreensaverSnapshotStoreError.snapshotMissing
        } catch {
            throw ScreensaverSnapshotStoreError.corruptedSnapshot
        }

        let snapshot: ScreensaverSnapshot
        do {
            snapshot = try Self.makeDecoder().decode(ScreensaverSnapshot.self, from: data)
        } catch {
            throw ScreensaverSnapshotStoreError.corruptedSnapshot
        }

        guard (1...ScreensaverSnapshot.currentSchemaVersion).contains(snapshot.schemaVersion) else {
            throw ScreensaverSnapshotStoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }

    /// 原子发布一份完整快照。
    func save(_ snapshot: ScreensaverSnapshot) throws {
        let fileManager = FileManager.default
        let temporaryURL = containerURL.appendingPathComponent(
            ".\(ScreensaverSharedConfiguration.snapshotFileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(
                at: containerURL,
                withIntermediateDirectories: true
            )
            let data = try Self.makeEncoder().encode(snapshot)
            try data.write(to: temporaryURL, options: [])

            if fileManager.fileExists(atPath: snapshotURL.path) {
                _ = try fileManager.replaceItemAt(
                    snapshotURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: snapshotURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw ScreensaverSnapshotStoreError.writeFailed
        }
    }

    /// 登出时删除 manifest 和 avatars/，不扫描或删除共享容器其它文件。
    func delete() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: snapshotURL.path) {
            try fileManager.removeItem(at: snapshotURL)
        }
        if fileManager.fileExists(atPath: avatarsDirectoryURL.path) {
            try fileManager.removeItem(at: avatarsDirectoryURL)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
