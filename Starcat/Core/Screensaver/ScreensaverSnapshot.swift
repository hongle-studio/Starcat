//
//  ScreensaverSnapshot.swift
//  Starcat
//
//  Direct 屏保只读快照。主应用是唯一写入者；.saver 进程只解码这份 JSON，
//  再按相对文件名读本地头像，不打开主库、也不访问 GitHub。
//

import Foundation

/// 屏保格子的最小卡片投影。`title` 只给缺图占位取首字母，UI 不得绘制全名。
struct ScreensaverSnapshotCard: Codable, Equatable, Sendable {
    let id: String
    let visualKey: String
    let title: String
    let imageFileName: String?
}

/// Owner 头像墙的版本化快照。
struct ScreensaverSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generatedAt: Date
    var userID: Int64
    var cards: [ScreensaverSnapshotCard]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date = Date(),
        userID: Int64,
        cards: [ScreensaverSnapshotCard]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.userID = userID
        self.cards = cards
    }
}
