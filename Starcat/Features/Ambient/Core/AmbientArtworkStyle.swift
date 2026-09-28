//
//  AmbientArtworkStyle.swift
//  Starcat
//
//  屏保格子的稳定占位。本地 PNG 由屏保自己解码，这里不碰 Kingfisher 或 GitHub URL。
//

import Foundation

/// 缺图时的色板与首字母。同一 card id 必须始终落到同一格颜色。
enum AmbientArtworkStyle {
    static let paletteCount = 8

    static func monogram(from title: String) -> String? {
        guard let character = title.first(where: { !$0.isWhitespace }) else { return nil }
        return String(character).uppercased()
    }

    /// Swift 的 `hashValue` 每进程随机；FNV-1a 保证同一 card id 永远映射同一占位色。
    static func paletteIndex(for cardID: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in cardID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(paletteCount))
    }
}
