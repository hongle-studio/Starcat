//
//  QuickSearchTextMatcherTests.swift
//  StarcatTests
//
//  快速搜索文本归一化与跨字段匹配的回归测试。
//

import Testing
@testable import Starcat

@Suite("QuickSearchTextMatcher")
struct QuickSearchTextMatcherTests {

    /// 空查询必须保留所有行，否则关闭搜索框后列表会继续处于过滤状态。
    @Test("空查询匹配任意候选字段")
    func emptyQueryMatches() {
        #expect(QuickSearchTextMatcher.matches("  ", candidates: [nil, "owner/repo"]))
    }

    /// 仓库名、说明等字段共用同一条本地化大小写不敏感规则。
    @Test("忽略大小写并跨字段匹配")
    func matchesAcrossFieldsIgnoringCase() {
        #expect(QuickSearchTextMatcher.matches("STARCAT", candidates: ["dong4j/starcat", nil]))
        #expect(QuickSearchTextMatcher.matches("知识库", candidates: ["Repository", "AI 知识库工具"]))
        #expect(!QuickSearchTextMatcher.matches("missing", candidates: ["dong4j/starcat", "AI 知识库工具"]))
    }
}
