//
//  CCSwitchProviderMapperTests.swift
//  StarcatTests
//
//  覆盖 Anthropic 开关、host 表、前缀去重、官方 OAuth skip。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CCSwitchProviderMapper")
struct CCSwitchProviderMapperTests {
    private func claudeRow(name: String = "DeepSeek", url: String, key: String = "sk-test-xxxx") -> CCSwitchProviderRow {
        CCSwitchProviderRow(
            id: "deepseek",
            appType: "claude",
            name: name,
            settingsConfig: "{\"env\":{\"ANTHROPIC_AUTH_TOKEN\":\"\(key)\",\"ANTHROPIC_BASE_URL\":\"\(url)\"}}",
            meta: "{}"
        )
    }

    @Test("DeepSeek /anthropic 在 adapter 可用时保持 Anthropic URL")
    func anthropicAvailableKeepsPath() {
        let mapped = CCSwitchProviderMapper.map(
            rows: [claudeRow(url: "https://api.deepseek.com/anthropic")],
            anthropicAvailable: true
        )
        let row = mapped.importable.first
        #expect(row?.provider == .anthropic)
        #expect(row?.baseURL == "https://api.deepseek.com/anthropic")
        #expect(mapped.skipped.isEmpty)
    }

    @Test("DeepSeek /anthropic 在 adapter 关闭时改写成 DeepSeek OpenAI 口")
    func anthropicUnavailableRewritesDeepSeek() {
        let mapped = CCSwitchProviderMapper.map(
            rows: [claudeRow(url: "https://api.deepseek.com/anthropic")],
            anthropicAvailable: false
        )
        let row = mapped.importable.first
        #expect(row?.provider == .deepSeek)
        #expect(row?.baseURL == AIServiceProvider.deepSeek.defaultBaseURL)
    }

    @Test("Codex MiniMax openai base_url 走 OpenAI 兼容")
    func codexMiniMax() {
        let row = CCSwitchProviderRow(
            id: "minimax",
            appType: "codex",
            name: "MiniMax",
            settingsConfig: "{\"auth\":{\"OPENAI_API_KEY\":\"sk-test-xxxx\"},\"config\":\"base_url = \\\"https://api.minimax.chat/v1\\\"\"}",
            meta: "{}"
        )
        let mapped = CCSwitchProviderMapper.map(rows: [row], anthropicAvailable: true)
        let imported = mapped.importable.first
        #expect(imported?.provider == .openAICompatible)
        #expect(imported?.baseURL.contains("minimax") == true)
    }

    @Test("Claude Official 无 Key 进入 skipped oauth")
    func officialSkipped() {
        let row = CCSwitchProviderRow(
            id: "official",
            appType: "claude",
            name: "Claude Official",
            settingsConfig: "{}",
            meta: "{}"
        )
        let mapped = CCSwitchProviderMapper.map(rows: [row], anthropicAvailable: true)
        #expect(mapped.importable.isEmpty)
        #expect(mapped.skipped.first?.skipReason == CCSwitchCredentialExtractor.skipOAuth)
    }

    @Test("显示名去重追加空格与数字")
    func uniqueDisplayName() {
        let first = CCSwitchProviderMapper.prefixedDisplayName("DeepSeek")
        #expect(first == "cc-switch: DeepSeek")
        let second = CCSwitchProviderMapper.uniquedDisplayName(first, existing: [first])
        #expect(second == "cc-switch: DeepSeek 2")
        let manual = CCSwitchProviderMapper.uniquedDisplayName(first, existing: ["DeepSeek"])
        #expect(manual == "cc-switch: DeepSeek")
    }
}
