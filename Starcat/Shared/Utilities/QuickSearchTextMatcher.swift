//
//  QuickSearchTextMatcher.swift
//  Starcat
//
//  中栏快速搜索共用的文本归一化与多字段匹配逻辑。
//

import Foundation

/// 统一各分类的快速搜索语义，避免同一个查询在不同中栏出现大小写或空白处理差异。
enum QuickSearchTextMatcher {
    /// 提交时收敛首尾空白；空字符串代表恢复完整列表。
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 查询为空时不过滤；否则任一可展示字段命中即可保留该卡片。
    static func matches(_ query: String, candidates: [String?]) -> Bool {
        let term = normalized(query)
        guard !term.isEmpty else { return true }
        return candidates.contains { candidate in
            candidate?.localizedCaseInsensitiveContains(term) == true
        }
    }
}
