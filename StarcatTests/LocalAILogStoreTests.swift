//
//  LocalAILogStoreTests.swift
//  StarcatTests
//
//  日志边界回归：只使用隔离临时目录/内存 store，不读取或清理用户的真实日志与模型。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Local AI log storage")
struct LocalAILogStoreTests {
    /// 每个测试有独立目录；清理范围始终是本测试自己创建的 UUID 子目录。
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StarcatLocalAILogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(_ number: Int) -> LocalAILogEvent {
        .init(stage: "test.event", message: "Event \(number)", fields: ["index": String(number)])
    }

    @Test("Records preserve order and retain only the bounded tail")
    func orderAndCountLimit() async {
        let store = LocalAILogStore(limits: .init(entries: 12), persistenceEnabled: false)
        for index in 0..<40 { store.record(event(index)) }
        let snapshot = await store.snapshot()
        #expect(snapshot.events.count == 12)
        #expect(snapshot.events.map(\.sequence) == Array(29...40).map(UInt64.init))
        #expect(snapshot.events.last?.fields["index"] == "39")
    }

    @Test("Encoded event bytes are bounded as well as entry count")
    func byteLimit() async throws {
        let store = LocalAILogStore(limits: .init(memoryBytes: 1_600), persistenceEnabled: false)
        for index in 0..<30 { store.record(event(index)) }
        let events = await store.snapshot().events
        let total = try events.reduce(0) { try $0 + JSONEncoder().encode($1).count }
        #expect(!events.isEmpty)
        #expect(total <= 1_600)
        #expect(events.count < 30)
    }

    @Test("A slow subscriber receives the latest complete snapshot, not an unbounded queue")
    func subscriptionCoalesces() async {
        let store = LocalAILogStore(persistenceEnabled: false)
        let subscription = store.updates()
        defer { subscription.cancel() }
        var iterator = subscription.stream.makeAsyncIterator()
        _ = await store.snapshot() // Wait until registration is committed.
        for index in 0..<40 { store.record(event(index)) }
        let expected = await store.snapshot()
        let actual = await iterator.next()
        #expect(actual?.events == expected.events)
        #expect(actual?.revision == expected.revision)
    }

    @Test("Closing a subscriber explicitly finishes it even when it is not awaiting next")
    func subscriptionCancellation() async {
        let store = LocalAILogStore(persistenceEnabled: false)
        let subscription = store.updates()
        var iterator = subscription.stream.makeAsyncIterator()
        _ = await iterator.next()
        subscription.cancel()
        _ = await store.snapshot() // FIFO barrier: unsubscribe must finish before a later record.
        store.record(event(1))
        _ = await store.snapshot()
        #expect(await iterator.next() == nil)
    }

    @Test("Backpressure is bounded and explicitly reported")
    func backpressureReported() async {
        let store = LocalAILogStore(limits: .init(pendingEntries: 0), persistenceEnabled: false)
        for index in 0..<300 { store.record(event(index)) }
        let snapshot = await store.snapshot()
        #expect(snapshot.droppedCount == 300)
        #expect(!snapshot.events.isEmpty)
        #expect(snapshot.events.allSatisfy { $0.stage == "logging.backpressure" })
    }

    @Test("Rotation keeps three bounded files and restores recent history")
    func rotationAndRecovery() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = LocalAILogStore.Limits(entries: 4, fileBytes: 1_100)
        let store = LocalAILogStore(directoryURL: root, limits: limits)
        for index in 0..<30 { store.record(event(index)) }
        let previous = await store.snapshot()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count == 3)
        for file in files {
            #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 1_100)
        }
        let restored = await LocalAILogStore(directoryURL: root, limits: limits).snapshot()
        #expect(restored.events == previous.events)
        #expect(restored.lastSequence == previous.lastSequence)
    }

    @Test("Clear is a FIFO barrier and removes only local AI files")
    func clearDoesNotResurrectOrDeleteOtherFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("diagnostic-log.jsonl")
        try Data("Other feature log".utf8).write(to: other)
        let store = LocalAILogStore(directoryURL: root, limits: .init(fileBytes: 1_100))
        for index in 0..<80 { store.record(event(index)) }
        try await store.clearAll()
        let cleared = await store.snapshot()
        #expect(cleared.events.isEmpty)
        #expect(cleared.clearGeneration == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["diagnostic-log.jsonl"])
        store.record(.init(stage: "new.activity", message: "New activity after clear."))
        let latest = await store.snapshot()
        #expect(latest.events.count == 1)
        #expect(latest.events.first?.stage == "new.activity")
        let export = root.appendingPathComponent("export.jsonl")
        try await store.export(to: export)
        let contents = try String(contentsOf: export, encoding: .utf8)
        #expect(contents.contains("new.activity"))
        #expect(!contents.contains("test.event"))
        #expect(try String(contentsOf: other, encoding: .utf8) == "Other feature log")
    }

    @Test("Damaged history lines are skipped without preventing subsequent logging")
    func corruptHistory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not-json\n{\"partial\":".utf8).write(to: root.appendingPathComponent("local-ai.jsonl"))
        let store = LocalAILogStore(directoryURL: root)
        store.record(event(1))
        #expect(await store.snapshot().events.count == 1)
        #expect(await LocalAILogStore(directoryURL: root).snapshot().events.count == 1)
    }

    @Test("Storage failures do not lose the live in-memory log or escape into inference")
    func writeFailureIsNonFatal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocker)
        let store = LocalAILogStore(directoryURL: blocker)
        store.record(event(1))
        let snapshot = await store.snapshot()
        #expect(snapshot.events.count == 1)
        #expect(snapshot.storageError?.contains("Log storage failed") == true)
        try FileManager.default.removeItem(at: blocker)
        store.record(event(2))
        #expect(await store.snapshot().storageError == nil)
    }

    @Test("Secrets, home paths and line breaks are sanitized")
    func redaction() throws {
        let event = LocalAILogEvent(stage: "test", message: "Bearer abc123456 /Users/private/model\nFORGED",
            fields: ["token": "api_key=sk-test0123456789", "long": String(repeating: "a", count: 2_000)])
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!json.contains("abc123456"))
        #expect(!json.contains("sk-test0123456789"))
        #expect(!json.contains("/Users/private/"))
        #expect(!event.line.contains("\n"))
        #expect(event.fields["long"]?.count == 256)
    }

    @Test("Missing-model generation logs actual model, task and failure without prompt text")
    func requestMetadataWithoutContents() async {
        let store = LocalAILogStore(persistenceEnabled: false)
        let model = LocalAIModelCatalog.llmMiniCPM5
        let client = LocalMLXClient(directoryForModelName: { throw LocalAIError.modelNotInstalled($0) })
        let request = AIChatRequest(systemPrompt: "PRIVATE SYSTEM CONTENT", userPrompt: "PRIVATE NOTE CONTENT",
            model: model.displayName, parameters: LocalAIGenerationPolicy.defaultParameters(model: model.displayName, capability: .chat),
            usageContext: .init(feature: .repoNote, phase: "generation"))
        await LocalAILogContext.$store.withValue(store) {
            do { _ = try await client.chat(request: request); Issue.record("Expected missing model") }
            catch { }
        }
        let snapshot = await store.snapshot()
        #expect(snapshot.events.map(\.stage) == ["request.received", "request.finished"])
        #expect(Set(snapshot.events.compactMap(\.requestID)).count == 1)
        #expect(snapshot.events.allSatisfy { $0.modelID == model.id && $0.feature == AIUsageFeature.repoNote.rawValue })
        #expect(!snapshot.events.map(\.line).joined().contains("PRIVATE"))
        #expect(snapshot.events.last?.level == .error)
    }
}
