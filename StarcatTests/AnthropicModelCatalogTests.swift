//
//  AnthropicModelCatalogTests.swift
//  StarcatTests
//
//  内置目录 API id 保持连字符；列表展示把 4-5 显示成 4.5。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AnthropicModelCatalog")
struct AnthropicModelCatalogTests {
    @Test("Claude 版本号展示为点分，请求仍用连字符 id")
    func displayNameUsesDots() {
        #expect(AnthropicModelCatalog.displayName(forAPIID: "claude-opus-4-1") == "claude-opus-4.1")
        #expect(AnthropicModelCatalog.displayName(forAPIID: "claude-sonnet-4-5") == "claude-sonnet-4.5")
        #expect(AnthropicModelCatalog.displayName(forAPIID: "claude-haiku-4-5") == "claude-haiku-4.5")
        #expect(
            AnthropicModelCatalog.displayName(forAPIID: "claude-sonnet-4-5-20250929")
                == "claude-sonnet-4.5-20250929"
        )
        #expect(AnthropicModelCatalog.bundledIDs.contains("claude-sonnet-4-5"))
        #expect(!AnthropicModelCatalog.bundledIDs.contains("claude-sonnet-4.5"))
    }

    @Test("非 Claude id 不改写")
    func nonClaudeIDsUnchanged() {
        #expect(AnthropicModelCatalog.displayName(forAPIID: "deepseek-v4-flash") == "deepseek-v4-flash")
    }
}
