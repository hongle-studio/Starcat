//
//  CCSwitchCredentialExtractorTests.swift
//  StarcatTests
//
//  覆盖 claude env、Codex TOML bearer、OAuth skip。fixture 使用 sk-test-xxxx，不含真实 Key。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CCSwitchCredentialExtractor")
struct CCSwitchCredentialExtractorTests {
    @Test("claude 只填 ANTHROPIC_AUTH_TOKEN")
    func claudeAuthToken() {
        let json = #"""
        {"env":{"ANTHROPIC_AUTH_TOKEN":"sk-test-xxxx","ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic"}}
        """#
        let result = CCSwitchCredentialExtractor.extract(
            appType: "claude",
            name: "DeepSeek",
            settingsJSON: json,
            metaJSON: nil
        )
        guard case .credentials(let url, let key, let hint) = result else {
            Issue.record("expected credentials")
            return
        }
        #expect(url == "https://api.deepseek.com/anthropic")
        #expect(key == "sk-test-xxxx")
        #expect(hint == .anthropic)
    }

    @Test("空 token 时回退 ANTHROPIC_API_KEY")
    func claudeAPIKeyFallback() {
        let json = #"""
        {"env":{"ANTHROPIC_AUTH_TOKEN":"","ANTHROPIC_API_KEY":"sk-test-key2","ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}
        """#
        let result = CCSwitchCredentialExtractor.extract(
            appType: "claude",
            name: "Claude",
            settingsJSON: json,
            metaJSON: nil
        )
        guard case .credentials(_, let key, _) = result else {
            Issue.record("expected credentials")
            return
        }
        #expect(key == "sk-test-key2")
    }

    @Test("Codex 只有 toml bearer、auth 为空")
    func codexTomlBearer() {
        let json = #"""
        {"auth":{},"config":"model_providers.foo.base_url = \"https://api.minimax.chat/v1\"\nexperimental_bearer_token = \"sk-test-toml1\""}
        """#
        let result = CCSwitchCredentialExtractor.extract(
            appType: "codex",
            name: "MiniMax",
            settingsJSON: json,
            metaJSON: nil
        )
        guard case .credentials(let url, let key, _) = result else {
            Issue.record("expected credentials \(result)")
            return
        }
        #expect(url.contains("minimax"))
        #expect(key == "sk-test-toml1")
    }

    @Test("Claude Official 无 Key 视为 oauth skip")
    func officialOAuthSkip() {
        let result = CCSwitchCredentialExtractor.extract(
            appType: "claude",
            name: "Claude Official",
            settingsJSON: "{}",
            metaJSON: #"{"provider_type":"claude_official"}"#
        )
        guard case .skip(let reason) = result else {
            Issue.record("expected skip")
            return
        }
        #expect(reason == CCSwitchCredentialExtractor.skipOAuth)
    }
}
