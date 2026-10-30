//
//  AnthropicModelCatalog.swift
//  Starcat
//
//  Anthropic 官方常用模型 id 的内置目录。
//
//  为什么需要：
//  - 不少国产中转只实现 `POST /v1/messages`，没有 `GET /v1/models`。
//  - 设置页「测试并获取模型」在 404 / 405 时回落到这份目录，再用一次最小 messages ping 验 Key。
//  - 401 / 403 禁止走这里，否则测试会假装成功。
//

import Foundation

/// Anthropic Messages API 的内置模型目录。
enum AnthropicModelCatalog {
    /// 官方常用 id。capability 一律按 chat 推断；Anthropic 无 embeddings。
    static let bundledIDs: [String] = [
        "claude-opus-4-1",
        "claude-sonnet-4-5",
        "claude-haiku-4-5"
    ]

    static func bundledDescriptors(providerID: String) -> [AIModelDescriptor] {
        bundledIDs.map { id in
            AIModelDescriptor(
                providerID: providerID,
                name: id,
                ownedBy: "anthropic",
                capability: .chat,
                isEnabled: true,
                isCustom: false
            )
        }
    }

    /// 列表展示用：官方 API id 是 `claude-sonnet-4-5`，营销名是 4.5。请求仍用原 id。
    static func displayName(forAPIID id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        return id.replacingOccurrences(
            of: #"(\d)-(\d)(?=-|$)"#,
            with: "$1.$2",
            options: .regularExpression
        )
    }
}
