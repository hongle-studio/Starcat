//
//  LocalAILogStore.swift
//  Starcat
//
//  有界本地 AI 日志：后台串行落盘、实时快照、轮转、导出及清空屏障。
//  不复用诊断问题的五分钟去重，也不影响 toolbar 的全局故障计数。
//

import Foundation
import OSLog

/// 快照使用有界数组；订阅只保留最新一份，慢窗口不会积累无限事件。
struct LocalAILogSnapshot: Sendable {
    var events: [LocalAILogEvent] = []
    var revision: UInt64 = 0
    var clearGeneration: UInt64 = 0
    var lastSequence: UInt64 = 0
    var droppedCount: Int = 0
    var storageError: String?
}

/// Sendable 约束：pending/scheduled 只在 inboxLock 内访问，其余可变状态仅由 queue 访问。
/// 使用一个 drain 而非每条日志一个 Task/Dispatch block，避免拥塞时日志任务本身无限增长。
final class LocalAILogStore: @unchecked Sendable {
    static let shared = LocalAILogStore(persistenceEnabled: !TestEnvironment.isRunning)

    struct Limits: Sendable {
        var entries = 2_000
        var memoryBytes = 2 * 1_024 * 1_024
        var fileBytes = 5 * 1_024 * 1_024
        var pendingEntries = 256
    }

    /// 显式取消可覆盖窗口在 UI 节流 sleep 期间关闭的情况，不依赖 iterator.next 的取消回调。
    struct Subscription: Sendable {
        let stream: AsyncStream<LocalAILogSnapshot>
        let cancel: @Sendable () -> Void
    }

    private enum Command {
        case record(LocalAILogEvent)
        case dropped(Int)
        case subscribe(UUID, AsyncStream<LocalAILogSnapshot>.Continuation)
        case unsubscribe(UUID)
        case snapshot(CheckedContinuation<LocalAILogSnapshot, Never>)
        case clear(CheckedContinuation<Void, Error>)
        case export(URL, CheckedContinuation<Void, Error>)
    }

    private let queue = DispatchQueue(label: "ink.starcat.local-ai-log", qos: .utility)
    private let inboxLock = NSLock()
    private var pending: [Command] = []
    private var pendingEvents = 0
    private var scheduled = false
    private let directory: URL
    private let limits: Limits
    private let persistenceEnabled: Bool
    private let logger = Logger(subsystem: AppConstants.logSubsystem, category: "local-ai")
    private let encoder: JSONEncoder
    private var loaded = false
    private var state = LocalAILogSnapshot()
    private var eventSizes: [Int] = []
    private var memoryBytes = 0
    private var subscribers: [UUID: AsyncStream<LocalAILogSnapshot>.Continuation] = [:]

    init(directoryURL: URL? = nil, limits: Limits = .init(), persistenceEnabled: Bool = true) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = directoryURL ?? support.appendingPathComponent(AppConstants.bundleIdentifier)
            .appendingPathComponent("diagnostics/local-ai", isDirectory: true)
        self.limits = limits
        self.persistenceEnabled = persistenceEnabled
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func record(_ event: LocalAILogEvent) { enqueue(.record(event)) }

    /// 注册与初始快照在同一串行边界完成，打开窗口时不会漏掉夹在中间的事件。
    func updates() -> Subscription {
        let id = UUID()
        let stream = AsyncStream<LocalAILogSnapshot>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in self?.enqueue(.unsubscribe(id)) }
            enqueue(.subscribe(id, continuation))
        }
        return Subscription(stream: stream, cancel: { [weak self] in self?.enqueue(.unsubscribe(id)) })
    }

    func snapshot() async -> LocalAILogSnapshot {
        await withCheckedContinuation { enqueue(.snapshot($0)) }
    }

    /// 只删除明确属于本功能的三个文件；成功返回意味着此前已提交的写入全部被清除。
    /// 清空之后的新事件照常记录；模型任务、系统 OSLog 和用户已导出的副本都不受影响。
    func clearAll() async throws {
        try await withCheckedThrowingContinuation { enqueue(.clear($0)) }
    }

    func export(to url: URL) async throws {
        try await withCheckedThrowingContinuation { enqueue(.export(url, $0)) }
    }

    private func enqueue(_ command: Command) {
        inboxLock.lock()
        if case .record = command, pendingEvents >= limits.pendingEntries {
            // 丢弃标记也按顺序排队，不能把清空之后的日志丢失误记到清空之前。
            if case .dropped(let count) = pending.last {
                pending[pending.count - 1] = .dropped(count + 1)
            } else { pending.append(.dropped(1)) }
        } else {
            if case .record = command { pendingEvents += 1 }
            pending.append(command)
        }
        let needsDrain = !scheduled
        scheduled = true
        inboxLock.unlock()
        if needsDrain { queue.async { self.drain() } }
    }

    private func drain() {
        loadHistoryIfNeeded()
        while true {
            inboxLock.lock()
            let commands = pending
            pending.removeAll(keepingCapacity: true)
            pendingEvents = 0
            if commands.isEmpty { scheduled = false }
            inboxLock.unlock()
            guard !commands.isEmpty else { return }
            for command in commands { process(command) }
        }
    }

    private func process(_ command: Command) {
        switch command {
        case .record(let event): append(event)
        case .dropped(let count):
            state.droppedCount += count
            append(.init(level: .warning, stage: "logging.backpressure",
                         message: "Log queue was full; events were dropped.", fields: ["count": String(count)]))
        case .subscribe(let id, let continuation):
            subscribers[id] = continuation
            continuation.yield(state)
        case .unsubscribe(let id): subscribers.removeValue(forKey: id)?.finish()
        case .snapshot(let continuation): continuation.resume(returning: state)
        case .clear(let continuation):
            do {
                if persistenceEnabled {
                    for file in files where FileManager.default.fileExists(atPath: file.path) {
                        try FileManager.default.removeItem(at: file)
                    }
                }
                state.events.removeAll()
                eventSizes.removeAll()
                memoryBytes = 0
                state.clearGeneration += 1
                state.storageError = nil
                state.droppedCount = 0
                publish()
                continuation.resume()
            } catch {
                storageFailed(error)
                publish()
                continuation.resume(throwing: error)
            }
        case .export(let url, let continuation):
            do { try exportFiles(to: url); continuation.resume() }
            catch { continuation.resume(throwing: error) }
        }
    }

    private func append(_ input: LocalAILogEvent) {
        var event = input
        state.lastSequence += 1
        event.sequence = state.lastSequence
        guard let data = try? encoder.encode(event) else { return }
        retain(event, size: data.count)
        let line = event.line
        switch event.level {
        case .info: logger.info("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        }
        if persistenceEnabled {
            do { try write(data); state.storageError = nil } catch { storageFailed(error) }
        }
        publish()
    }

    private func retain(_ event: LocalAILogEvent, size: Int) {
        state.events.append(event)
        eventSizes.append(size)
        memoryBytes += size
        var count = 0
        while state.events.count - count > limits.entries || memoryBytes > limits.memoryBytes {
            memoryBytes -= eventSizes[count]
            count += 1
        }
        if count > 0 {
            state.events.removeFirst(count)
            eventSizes.removeFirst(count)
        }
    }

    private func publish() {
        state.revision += 1
        for continuation in subscribers.values { continuation.yield(state) }
    }

    /// 名称固定，不枚举目录：清空操作绝不波及诊断问题、模型文件或其它功能日志。
    private var files: [URL] {
        ["local-ai.2.jsonl", "local-ai.1.jsonl", "local-ai.jsonl"].map {
            directory.appendingPathComponent($0)
        }
    }

    private func write(_ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = files
        let current = paths[2]
        let size = (try? fm.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 0, size + data.count + 1 > limits.fileBytes {
            if fm.fileExists(atPath: paths[0].path) { try fm.removeItem(at: paths[0]) }
            if fm.fileExists(atPath: paths[1].path) { try fm.moveItem(at: paths[1], to: paths[0]) }
            try fm.moveItem(at: current, to: paths[1])
        }
        if !fm.fileExists(atPath: current.path) { fm.createFile(atPath: current.path, contents: nil) }
        let handle = try FileHandle(forUpdating: current)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let tail = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            // 崩溃留下的半行不能与下一条正常 JSON 拼接，否则新日志也会无法恢复。
            if tail != Data([10]) { try handle.write(contentsOf: Data([10])) }
        }
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([10]))
    }

    /// 每个文件最多读配置上限；损坏 JSON/半行跳过，历史读取不会无界扩张。
    private func loadHistoryIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard persistenceEnabled else { return }
        let decoder = JSONDecoder()
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: limits.fileBytes) else { continue }
            for line in data.split(separator: 10) {
                guard let event = try? decoder.decode(LocalAILogEvent.self, from: Data(line)) else { continue }
                state.lastSequence = max(state.lastSequence, event.sequence)
                retain(event, size: line.count)
            }
        }
    }

    private func storageFailed(_ error: Error) {
        state.storageError = "Log storage failed (code \((error as NSError).code))."
        logger.error("Local AI log storage failed; code=\((error as NSError).code)")
    }

    /// 导出在相同队列内逐块复制，轮转或清空不能在导出中途改写输入文件。
    private func exportFiles(to url: URL) throws {
        guard !files.contains(url.standardizedFileURL) else { throw CocoaError(.fileWriteInvalidFileName) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        for file in files where persistenceEnabled && FileManager.default.fileExists(atPath: file.path) {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var remaining = limits.fileBytes
            while remaining > 0, let data = try input.read(upToCount: min(65_536, remaining)), !data.isEmpty {
                try output.write(contentsOf: data)
                remaining -= data.count
            }
        }
        if !persistenceEnabled {
            for event in state.events {
                try output.write(contentsOf: encoder.encode(event))
                try output.write(contentsOf: Data([10]))
            }
        }
    }
}
