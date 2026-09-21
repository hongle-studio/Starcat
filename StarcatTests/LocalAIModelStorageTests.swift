//
//  LocalAIModelStorageTests.swift
//  StarcatTests
//
//  本地模型存储：manifest 读写、安装列表扫描、脏目录容错、清理与用量统计。
//  通过 `LocalAIModelStorage.testRootOverride` 把 models 根目录指到临时目录，
//  避免污染测试宿主的真实 Application Support。
//

import Foundation
import Testing
@testable import Starcat

@Suite("LocalAIModelStorage")
struct LocalAIModelStorageTests {

    private var tempRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-storage-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// 写一个假模型目录（带或不带 manifest）。
    private func makeModelDirectory(
        entry: LocalAIModelCatalogEntry, revision: String, manifest: LocalAIInstalledModel?
    ) throws -> URL {
        let directory = try LocalAIModelStorage.modelDirectory(entry: entry, revision: revision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("model.safetensors")
        try Data("weights".utf8).write(to: fileURL)
        if let manifest {
            try LocalAIModelStorage.save(manifest, in: directory)
        }
        return directory
    }

    private func sampleManifest(_ entry: LocalAIModelCatalogEntry, revision: String) -> LocalAIInstalledModel {
        LocalAIInstalledModel(
            id: entry.id,
            displayName: entry.displayName,
            type: entry.type,
            revision: revision,
            installedAt: Date(timeIntervalSince1970: 100),
            sourceKind: .huggingFace,
            files: [LocalAIFileRecord(name: "model.safetensors", sha256: "abc", sizeBytes: 7)],
            embeddingDimension: entry.embeddingDimension,
            totalBytes: 7)
    }

    @Test("manifest 写后可读且字段一致")
    func manifestRoundtrip() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        let entry = LocalAIModelCatalog.embedding
        let revision = "rev123"
        let manifest = sampleManifest(entry, revision: revision)
        let directory = try LocalAIModelStorage.modelDirectory(entry: entry, revision: revision)
        try LocalAIModelStorage.save(manifest, in: directory)

        let loaded = try LocalAIModelStorage.loadManifest(from: directory)
        #expect(loaded == manifest)
        #expect(loaded?.revision == "rev123")
        #expect(LocalAIModelStorage.installedDirectoryURL(entryID: entry.id)?.path == directory.path)
    }

    @Test("无 manifest 的脏目录被扫描跳过且可清理")
    func dirtyDirectorySkipped() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        let entry = LocalAIModelCatalog.llm
        _ = try makeModelDirectory(entry: entry, revision: "r1", manifest: nil)

        #expect(try LocalAIModelStorage.listInstalled().isEmpty)
        #expect(LocalAIModelStorage.installedDirectoryURL(entryID: entry.id) == nil)
    }

    @Test("listInstalled 覆盖多个类型子目录")
    func listAcrossTypes() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        _ = try makeModelDirectory(
            entry: LocalAIModelCatalog.embedding, revision: "r1",
            manifest: sampleManifest(LocalAIModelCatalog.embedding, revision: "r1"))
        _ = try makeModelDirectory(
            entry: LocalAIModelCatalog.reranker, revision: "r2",
            manifest: sampleManifest(LocalAIModelCatalog.reranker, revision: "r2"))

        let installed = try LocalAIModelStorage.listInstalled()
        #expect(Set(installed.map(\.id)) == [LocalAIModelCatalog.embedding.id, LocalAIModelCatalog.reranker.id])
    }

    @Test("损坏的 manifest 抛出明确错误")
    func corruptedManifestThrows() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        let entry = LocalAIModelCatalog.embedding
        let directory = try LocalAIModelStorage.modelDirectory(entry: entry, revision: "rx")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: LocalAIModelStorage.manifestURL(in: directory))

        #expect(throws: LocalAIModelStorage.StorageError.manifestCorrupted(directory.lastPathComponent)) {
            _ = try LocalAIModelStorage.loadManifest(from: directory)
        }
    }

    @Test("删除模型目录与残留 .part 清理")
    func deleteAndPartialCleanup() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        let entry = LocalAIModelCatalog.embedding
        let directory = try makeModelDirectory(
            entry: entry, revision: "r1",
            manifest: sampleManifest(entry, revision: "r1"))
        let partURL = directory.appendingPathComponent("tokenizer.json.part")
        try Data("partial".utf8).write(to: partURL)

        try LocalAIModelStorage.remove(modelDirectory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        // 另一个目录残留 .part，应被 cleanPartialFiles 清掉。
        let other = try LocalAIModelStorage.modelDirectory(entry: entry, revision: "r2")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherPart = other.appendingPathComponent("model.safetensors.part")
        try Data("x".utf8).write(to: otherPart)
        LocalAIModelStorage.cleanPartialFiles()
        #expect(!FileManager.default.fileExists(atPath: otherPart.path))
    }

    @Test("目录用量统计大于零")
    func directorySize() throws {
        let root = tempRoot
        LocalAIModelStorage.testRootOverride = root
        defer {
            LocalAIModelStorage.testRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        _ = try makeModelDirectory(
            entry: LocalAIModelCatalog.embedding, revision: "r1",
            manifest: sampleManifest(LocalAIModelCatalog.embedding, revision: "r1"))
        #expect(LocalAIModelStorage.totalDiskUsage() > 0)
    }
}
