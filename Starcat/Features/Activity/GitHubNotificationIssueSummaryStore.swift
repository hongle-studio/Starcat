//
//  GitHubNotificationIssueSummaryStore.swift
//  Starcat
//
//  应用级 Issue 总结会话缓存。只持有本次进程的任务和结果，不写数据库或磁盘，
//  因此面板关闭 / 切帖与生成任务解耦；切换账号则立即取消并清空全部旧会话。
//

import Foundation

/// 字典不参与 Observation：SwiftUI body 查询已有会话不能触发整页重绘或更新循环。
@MainActor
final class GitHubNotificationIssueSummaryStore {
    private static let retainedSessionLimit = 12
    private var scopeRevision: UInt64?
    private var sessions: [Key: GitHubNotificationIssueSummarySession] = [:]
    private var accessOrder: [Key] = []

    /// 同一账号、Issue 和输出语言复用同一对象；重新打开面板不会重新请求模型。
    func session(threadId: String, scopeRevision: UInt64, language: String) -> GitHubNotificationIssueSummarySession {
        if self.scopeRevision != scopeRevision { reset(scopeRevision: scopeRevision) }
        let key = Key(threadId: threadId, language: language)
        let session: GitHubNotificationIssueSummarySession
        if let existing = sessions[key] {
            session = existing
        } else {
            session = GitHubNotificationIssueSummarySession()
            sessions[key] = session
        }
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        pruneIdleSessions(keeping: key)
        return session
    }

    /// AppDependencies 在数据库账号作用域真正切换后调用；不依赖详情页是否仍在前台。
    func reset(scopeRevision: UInt64) {
        sessions.values.forEach { $0.discard() }
        sessions.removeAll()
        accessOrder.removeAll()
        self.scopeRevision = scopeRevision
    }

    /// 仅淘汰最久未查看的非运行会话；后台运行中的请求不得因浏览其它 Issue 而被停止。
    private func pruneIdleSessions(keeping current: Key) {
        while sessions.count > Self.retainedSessionLimit {
            guard let oldest = accessOrder.first(where: { key in
                key != current && sessions[key]?.isGenerating == false
            }) else { return }
            sessions.removeValue(forKey: oldest)
            accessOrder.removeAll { $0 == oldest }
        }
    }

    private struct Key: Hashable {
        let threadId: String
        let language: String
    }
}
