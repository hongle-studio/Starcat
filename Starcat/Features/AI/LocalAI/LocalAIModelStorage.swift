//
//  LocalAIModelStorage.swift
//  Starcat
//
//  本地 AI 模型磁盘布局与安装清单（manifest）读写。
//
//  关键约束：
//  - 模型是「机器级资源」，不进 per-user 数据库：数据库按 users/<userId>/ 隔离，
//    而模型应该跨账号共享。安装状态单一真源 = 每个模型目录里的 manifest.json。
//  - 路径统一走 `FileManager.applicationSupportDirectory + AppConstants.bundleIdentifier`，
//    与 `CacheDirectoryLocator.applicationSupportRoot()` 同一惯例，禁止硬编码
//    `~/Library/...`（沙盒 / Direct 双渠道会落到不同容器）。
//  - 目录名 = `<entry.id>@<revision>`：revision 进目录名让版本可追溯；同时保证
//    Qwen3 reranker 的目录名包含 "rerank"，满足 `RerankerModelFactory` 的
//    verified-naming 要求。
//  - 启动扫描容忍脏目录：没有 manifest 的目录视为未完成下载，可被清理。
//

import Foundation
import CryptoKit

/// 单个已安装文件的校验记录。SHA256 在下载完成时流式计算，供后续完整性检查。
struct LocalAIFileRecord: Codable, Equatable, Sendable {
    var name: String
    var sha256: String
    var sizeBytes: Int64
}

/// 一个已安装模型的安装清单。
struct LocalAIInstalledModel: Codable, Equatable, Identifiable, Sendable {
    /// catalog entry id，如 `qwen3-embedding-0.6b-8bit`。
    var id: String
    var displayName: String
    var type: LocalAIModelType
    /// 安装时解析出的仓库 revision（commit SHA）。
    var revision: String
    var installedAt: Date
    var sourceKind: LocalAIModelSource.Kind
    var files: [LocalAIFileRecord]
    /// embedding 专用维度，写入向量元数据口径。
    var embeddingDimension: Int?
    var totalBytes: Int64

    var idWithRevision: String { "\(id)@\(revision)" }
}

/// manifest 存取 / 目录解析的纯函数集合。线程安全：无状态，全部显式传参。
enum LocalAIModelStorage {

    /// 单测注入的 models 根目录。仅 `TestEnvironment.isRunning` 时生效，
    /// 避免测试把文件写进测试宿主真实的 Application Support。
    nonisolated(unsafe) static var testRootOverride: URL?

    enum StorageError: LocalizedError, Equatable {
        case applicationSupportUnavailable
        case manifestCorrupted(String)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return String.l10n("settings.localai.error.applicationSupportUnavailable")
            case .manifestCorrupted(let path):
                return String(
                    format: String.l10n("settings.localai.error.manifestCorruptedFormat"), path)
            }
        }
    }

    // MARK: - 路径解析

    /// `Application Support/<bundleId>/models/`。
    static func modelsRootURL(fileManager: FileManager = .default) throws -> URL {
        if TestEnvironment.isRunning, let testRootOverride {
            return testRootOverride
        }
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw StorageError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// 某个 catalog 类型在 models 下的子目录（embedding / reranker / llm）。
    static func typeDirectory(
        for type: LocalAIModelType, fileManager: FileManager = .default
    ) throws -> URL {
        try modelsRootURL(fileManager: fileManager)
            .appendingPathComponent(type.storagePathComponent, isDirectory: true)
    }

    /// 单个模型安装目录：`models/<type>/<entry.id>@<revision>/`。
    static func modelDirectory(
        entry: LocalAIModelCatalogEntry, revision: String, fileManager: FileManager = .default
    ) throws -> URL {
        try typeDirectory(for: entry.type, fileManager: fileManager)
            .appendingPathComponent("\(entry.id)@\(revision)", isDirectory: true)
    }

    static func manifestURL(in modelDirectory: URL) -> URL {
        modelDirectory.appendingPathComponent("manifest.json")
    }

    /// 线程安全便捷查询：按 entry id 扫描磁盘解析安装目录。
    ///
    /// 为什么不走 `LocalAIModelManager`：manager 是 @MainActor 的 UI 状态机，而
    /// `LocalMLXClient` 的模型目录解析发生在推理任务上下文（任意线程）。磁盘扫描
    /// 是本模块的唯一真源，推理路径直接读它，避免跨 actor 阻塞。
    static func installedDirectoryURL(
        entryID: String, fileManager: FileManager = .default
    ) -> URL? {
        guard let entry = LocalAIModelCatalog.entry(id: entryID),
            let manifest = try? listInstalled(fileManager: fileManager)
                .first(where: { $0.id == entryID })
        else { return nil }
        return try? modelDirectory(entry: entry, revision: manifest.revision, fileManager: fileManager)
    }

    // MARK: - manifest 读写

    static func save(
        _ manifest: LocalAIInstalledModel, in modelDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: modelDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettySorted.encode(manifest)
        try data.write(to: manifestURL(in: modelDirectory), options: .atomic)
    }

    static func loadManifest(
        from modelDirectory: URL, fileManager: FileManager = .default
    ) throws -> LocalAIInstalledModel? {
        let url = manifestURL(in: modelDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder.manifest.decode(
                LocalAIInstalledModel.self, from: Data(contentsOf: url))
        } catch {
            throw StorageError.manifestCorrupted(modelDirectory.lastPathComponent)
        }
    }

    /// 扫描全部类型子目录，返回已安装模型列表（按类型 + id 排序，保证 UI 稳定）。
    ///
    /// 无 manifest 的目录视为未完成下载，静默跳过（由 `cleanIncompleteDownloads` 物理清理）。
    static func listInstalled(fileManager: FileManager = .default) throws -> [LocalAIInstalledModel] {
        var result: [LocalAIInstalledModel] = []
        for type in LocalAIModelType.allCases {
            let typeDir = try typeDirectory(for: type, fileManager: fileManager)
            let children = (try? fileManager.contentsOfDirectory(
                at: typeDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { continue }
                if let manifest = try loadManifest(from: child, fileManager: fileManager) {
                    result.append(manifest)
                }
            }
        }
        return result
    }

    /// 删除整个模型目录。
    static func remove(modelDirectory: URL) throws {
        try FileManager.default.removeItem(at: modelDirectory)
    }

    // MARK: - 用量与清理

    /// models 根目录总占用（字节）。
    static func totalDiskUsage(fileManager: FileManager = .default) -> Int64 {
        guard let root = try? modelsRootURL(fileManager: fileManager) else { return 0 }
        return directorySize(at: root, fileManager: fileManager)
    }

    static func directorySize(
        at url: URL, fileManager: FileManager = .default
    ) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// 清理残留的 `.part` 临时文件（断点续传的中间产物）。
    static func cleanPartialFiles(fileManager: FileManager = .default) {
        guard let root = try? modelsRootURL(fileManager: fileManager),
            let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "part" {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// 流式计算文件 SHA256。
    static func sha256(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder {
    /// manifest 用：pretty 输出 + keys 排序，保证同一内容序列化结果稳定（diff 友好）。
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var manifest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
