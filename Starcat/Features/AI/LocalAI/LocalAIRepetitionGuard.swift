//
//  LocalAIRepetitionGuard.swift
//  Starcat
//
//  检测流式生成的连续重复后缀，不删除或改写用户内容。只接收增量，不接收累计快照。
//  至少 512 字节且连续三个周期才触发，避免普通标题、短列表和标点重复被误判。
//

import Foundation

/// 有界后缀窗口 + KMP 前缀表：每 64 字节做一次线性检查，不逐 token 重扫整篇输出。
struct LocalAIRepetitionGuard {
    private static let windowSize = 12_288
    private var tail: [UInt8] = []
    private var uncheckedBytes = 0

    /// 检查任意分块方式的输出；大 chunk 也逐检查点处理，不会跳过其中的重复区间。
    mutating func ingest(_ delta: String) -> Bool {
        for byte in delta.utf8 {
            tail.append(byte)
            uncheckedBytes += 1
            guard uncheckedBytes >= 64 else { continue }
            uncheckedBytes = 0
            if tail.count > Self.windowSize { tail = Array(tail.suffix(Self.windowSize)) }
            if hasRepeatedSuffix { return true }
        }
        return false
    }

    private var hasRepeatedSuffix: Bool {
        guard tail.count >= 512 else { return false }
        // 反转后检查“前缀”的周期，等价于只检查原输出当前末尾，避免反复命中历史重复。
        let bytes = Array(tail.reversed())
        var prefix = [Int](repeating: 0, count: bytes.count)
        for index in 1..<bytes.count {
            var matched = prefix[index - 1]
            while matched > 0, bytes[index] != bytes[matched] { matched = prefix[matched - 1] }
            if bytes[index] == bytes[matched] { matched += 1 }
            prefix[index] = matched
            let length = index + 1
            let period = length - matched
            if length >= 512, length >= 3 * period { return true }
        }
        return false
    }
}
