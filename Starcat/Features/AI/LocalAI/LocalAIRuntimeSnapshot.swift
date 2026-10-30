//
//  LocalAIRuntimeSnapshot.swift
//  Starcat
//
//  本地 AI 运行时的值快照与内存策略。安装状态仍来自磁盘 manifest，不能当作驻留状态。
//

import Foundation

/// 驻留状态与磁盘安装状态分离；已下载的模型不一定已经加载。
enum LocalAIRuntimePhase: String, Sendable {
    case notLoaded, unloaded, loading, ready, running, unloading, failed
    var localizationKey: String { "toolbar.localai.state.\(rawValue)" }
}

/// 只保存展示元数据，不能持有模型或张量，否则状态面板本身会阻止内存释放。
struct LocalAIResidentModel: Sendable {
    var directory: URL
    var phase: LocalAIRuntimePhase
    /// 串行加载前后的 activeMemory 增量；共享缓存单独统计，不虚构逐模型 GPU 分摊。
    var loadedBytes: Int = 0
    var lastUsed: Date = Date()
    var error: String?
}

/// 可安全跨 actor 传给 SwiftUI 的快照；内存统计均为 MLX 分配，不是整个进程用量。
struct LocalAIRuntimeSnapshot: Sendable {
    var models: [LocalAIModelType: LocalAIResidentModel] = [:]
    var activeBytes = 0
    var cacheBytes = 0
    var peakBytes = 0
    var budgetBytes = LocalAIMemoryPolicy.budget(
        physicalMemory: ProcessInfo.processInfo.physicalMemory)
    var queuedCount = 0
    var notice: String?
}

/// 明确限制缓存、上下文和批次；memoryLimit 是 MLX 调度阈值，另需运行时预算监测。
enum LocalAIMemoryPolicy {
    static let cacheBytes = 256 * 1_024 * 1_024
    static let inputTokens = 8_192
    static let outputTokens = 8_192
    static let idleSeconds: TimeInterval = 60

    static func budget(physicalMemory: UInt64) -> Int {
        min(8 * 1_024 * 1_024 * 1_024, max(2 * 1_024 * 1_024 * 1_024, Int(physicalMemory / 4)))
    }
}
