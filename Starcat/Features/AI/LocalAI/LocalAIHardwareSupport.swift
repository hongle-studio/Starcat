//
//  LocalAIHardwareSupport.swift
//  Starcat
//
//  本地 AI（MLX）硬件能力检测。
//
//  为什么需要：MLX 只能在 Apple Silicon（统一内存 + Metal）上运行，而全仓此前没有任何
//  架构判断。Intel Mac 的兜底策略是「不出现 + 不注入」：内置 profile 不 seed、设置页
//  不展示模型管理区、任务默认回退 legacy provider——避免 MLX 在运行期崩溃。
//
//  关键约束：
//  - 用 `sysctl("hw.optional.arm64")` 而不是编译条件 `#if arch(arm64)`：后者只描述
//    当前构建产物，Apple Silicon 上的 Rosetta / Intel 通用二进制会误判。
//  - 结果进程内不变，缓存成常量避免设置页每次渲染都走 sysctl。
//

import Foundation

enum LocalAIHardwareSupport {

    /// 当前机器是否为 Apple Silicon。进程生命周期内不变。
    static let isAppleSilicon: Bool = {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        // Intel 机器上该 key 不存在（返回非 0），只有 Apple Silicon 返回 1。
        return result == 0 && value == 1
    }()

    /// 物理内存字节数，用于安装前的「内存建议」提示。
    static var totalPhysicalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// 本机是否能启用本地 AI：Apple Silicon 且MLX 可用。
    static var isLocalAIAvailable: Bool {
        isAppleSilicon
    }
}
