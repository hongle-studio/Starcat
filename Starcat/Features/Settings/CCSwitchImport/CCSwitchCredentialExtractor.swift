//
//  CCSwitchCredentialExtractor.swift
//  Starcat
//
//  按 CC Switch `app_type` 从 `settings_config` 抽出 Base URL 与 API Key。
//  形状对齐上游 `Provider::resolve_usage_credentials`（farion1231/cc-switch）。
//
//  关键约束：
//  - OAuth / 托管登录 / 占位符 Key 必须 skip，不能把假密钥写进 Starcat Keychain。
//  - 抽不到 Key 也 skip。禁止把空串当成可导项。
//

import Foundation

enum CCSwitchProtocolHint: Equatable, Sendable {
    case anthropic
    case openaiCompatible
    case unknown
}

enum CCSwitchExtractResult: Equatable, Sendable {
    case credentials(baseURL: String, apiKey: String, hint: CCSwitchProtocolHint)
    case skip(reasonKey: String)
}

enum CCSwitchCredentialExtractor {
    static let skipNoKey = "settings.ai.provider.importCCSwitch.skip.noKey"
    static let skipOAuth = "settings.ai.provider.importCCSwitch.skip.oauth"
    static let skipPlaceholder = "settings.ai.provider.importCCSwitch.skip.placeholder"
    static let skipBadJSON = "settings.ai.provider.importCCSwitch.skip.badJSON"

    private static let oauthProviderTypes: Set<String> = [
        "codex_oauth",
        "xai_oauth",
        "github_copilot"
    ]

    private static let officialNames: Set<String> = [
        "claude official",
        "openai official",
        "google official"
    ]

    static func extract(
        appType: String,
        name: String,
        settingsJSON: String,
        metaJSON: String?
    ) -> CCSwitchExtractResult {
        if isOAuthIdentity(name: name, metaJSON: metaJSON) {
            return .skip(reasonKey: skipOAuth)
        }
        guard let settings = parseObject(settingsJSON) else {
            return .skip(reasonKey: skipBadJSON)
        }

        let extracted: (baseURL: String, apiKey: String, hint: CCSwitchProtocolHint)
        switch appType {
        case "claude", "claude_desktop":
            extracted = (
                string(settings, ["env", "ANTHROPIC_BASE_URL"]),
                firstNonEmpty(
                    string(settings, ["env", "ANTHROPIC_AUTH_TOKEN"]),
                    string(settings, ["env", "ANTHROPIC_API_KEY"]),
                    string(settings, ["env", "OPENROUTER_API_KEY"]),
                    string(settings, ["env", "GOOGLE_API_KEY"])
                ),
                .anthropic
            )
        case "codex":
            let toml = string(settings, ["config"])
            extracted = (
                firstNonEmpty(tomlValue(toml, key: "base_url"), nestedProviderBaseURL(toml)),
                firstNonEmpty(
                    string(settings, ["auth", "OPENAI_API_KEY"]),
                    tomlValue(toml, key: "experimental_bearer_token")
                ),
                .openaiCompatible
            )
        case "gemini":
            extracted = (
                string(settings, ["env", "GOOGLE_GEMINI_BASE_URL"]),
                firstNonEmpty(
                    string(settings, ["env", "GEMINI_API_KEY"]),
                    string(settings, ["env", "GOOGLE_API_KEY"])
                ),
                .unknown
            )
        case "opencode":
            extracted = (
                firstNonEmpty(string(settings, ["options", "baseURL"]), string(settings, ["options", "baseUrl"])),
                string(settings, ["options", "apiKey"]),
                .openaiCompatible
            )
        case "openclaw":
            extracted = (
                firstNonEmpty(string(settings, ["baseUrl"]), string(settings, ["baseURL"])),
                string(settings, ["apiKey"]),
                .openaiCompatible
            )
        case "hermes":
            extracted = (
                string(settings, ["base_url"]),
                string(settings, ["api_key"]),
                .openaiCompatible
            )
        case "grokbuild":
            let toml = string(settings, ["config"])
            extracted = (
                tomlValue(toml, key: "base_url"),
                firstNonEmpty(tomlValue(toml, key: "api_key"), tomlValue(toml, key: "experimental_bearer_token")),
                .openaiCompatible
            )
        default:
            extracted = (
                firstNonEmpty(string(settings, ["baseURL"]), string(settings, ["base_url"])),
                firstNonEmpty(string(settings, ["apiKey"]), string(settings, ["api_key"])),
                .unknown
            )
        }

        if let skip = keySkipReason(extracted.apiKey) {
            return .skip(reasonKey: skip)
        }
        return .credentials(baseURL: extracted.baseURL, apiKey: extracted.apiKey, hint: extracted.hint)
    }

    static func isOAuthIdentity(name: String, metaJSON: String?) -> Bool {
        if officialNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return true
        }
        guard let metaJSON, let meta = parseObject(metaJSON) else { return false }
        let providerType = string(meta, ["provider_type"]).lowercased()
        if oauthProviderTypes.contains(providerType) {
            return true
        }
        if bool(meta, ["uses_managed_account_auth"]) == true {
            return true
        }
        return false
    }

    static func keySkipReason(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return skipNoKey }
        if trimmed == "PROXY_TOKEN_PLACEHOLDER" { return skipPlaceholder }
        if trimmed.allSatisfy({ $0 == "*" }) { return skipPlaceholder }
        let visible = trimmed.filter { !$0.isWhitespace }
        if visible.count < 8 { return skipPlaceholder }
        return nil
    }

    // MARK: - JSON / TOML helpers

    private static func parseObject(_ json: String) -> [String: Any]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func string(_ object: [String: Any], _ path: [String]) -> String {
        var current: Any? = object
        for key in path {
            guard let dict = current as? [String: Any] else { return "" }
            current = dict[key]
        }
        if let value = current as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func bool(_ object: [String: Any], _ path: [String]) -> Bool? {
        var current: Any? = object
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        if let value = current as? Bool { return value }
        if let value = current as? NSNumber { return value.boolValue }
        return nil
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }

    /// Codex TOML 没有标准库，只抽第一处 `key = "value"`。
    static func tomlValue(_ toml: String, key: String) -> String {
        guard !toml.isEmpty else { return "" }
        let pattern = #"\#(NSRegularExpression.escapedPattern(for: key))\s*=\s*"(.*?)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let range = NSRange(toml.startIndex..<toml.endIndex, in: toml)
        guard let match = regex.firstMatch(in: toml, range: range),
              let valueRange = Range(match.range(at: 1), in: toml) else {
            return ""
        }
        return String(toml[valueRange])
    }

    private static func nestedProviderBaseURL(_ toml: String) -> String {
        tomlValue(toml, key: "base_url")
    }
}
