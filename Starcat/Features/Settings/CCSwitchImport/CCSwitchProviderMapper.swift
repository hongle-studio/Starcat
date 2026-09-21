//
//  CCSwitchProviderMapper.swift
//  Starcat
//
//  把 CC Switch 行映射成 Starcat `AIProviderProfile` 候选。永远新增，不覆盖已有配置。
//
//  判定顺序见文档 69：Anthropic adapter 可用时 Claude / `*/anthropic` 原样导入；
//  否则走 OpenAI host 表。DeepSeek `/anthropic` 在 adapter 关闭时才改写成 `.deepSeek`。
//

import Foundation

struct CCSwitchImportCandidate: Identifiable, Equatable {
    var id: String
    var sourceName: String
    var displayName: String
    var provider: AIServiceProvider
    var baseURL: String
    var apiKey: String
    var appType: String
    var skipReason: String?

    var isImportable: Bool { skipReason == nil }

    /// 预览只展示掩码，完整 Key 只在确认后写入 Keychain。
    var maskedKey: String {
        let key = apiKey
        guard key.count >= 4 else {
            return String(repeating: "•", count: max(4, key.count))
        }
        return "••••" + key.suffix(4)
    }
}

struct CCSwitchImportPreview: Equatable {
    var sourcePath: String
    var importable: [CCSwitchImportCandidate]
    var skipped: [CCSwitchImportCandidate]
}

enum CCSwitchProviderMapper {
    static let displayNamePrefix = "cc-switch: "
    static let skipUnsupported = "settings.ai.provider.importCCSwitch.skip.unsupportedProtocol"
    static let skipMissingBaseURL = "settings.ai.provider.importCCSwitch.skip.unsupportedProtocol"

    static var isAnthropicAdapterAvailable: Bool {
        AIServiceProvider.allCases.contains { $0.rawValue == "anthropic" }
    }

    static func map(
        rows: [CCSwitchProviderRow],
        anthropicAvailable: Bool = isAnthropicAdapterAvailable
    ) -> (importable: [CCSwitchImportCandidate], skipped: [CCSwitchImportCandidate]) {
        var importable: [CCSwitchImportCandidate] = []
        var skipped: [CCSwitchImportCandidate] = []
        for row in rows {
            let candidate = mapRow(row, anthropicAvailable: anthropicAvailable)
            if candidate.skipReason == nil {
                importable.append(candidate)
            } else {
                skipped.append(candidate)
            }
        }
        return (importable, skipped)
    }

    static func preview(
        rows: [CCSwitchProviderRow],
        sourcePath: String,
        anthropicAvailable: Bool = isAnthropicAdapterAvailable
    ) -> CCSwitchImportPreview {
        let mapped = map(rows: rows, anthropicAvailable: anthropicAvailable)
        return CCSwitchImportPreview(
            sourcePath: sourcePath,
            importable: mapped.importable,
            skipped: mapped.skipped
        )
    }

    static func prefixedDisplayName(_ sourceName: String) -> String {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Provider" : trimmed
        return displayNamePrefix + base
    }

    /// 大小写敏感查重。冲突则追加空格 + 从 2 起的整数。
    static func uniquedDisplayName(_ base: String, existing: [String]) -> String {
        let names = Set(existing)
        if !names.contains(base) { return base }
        var index = 2
        while names.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    private static func mapRow(
        _ row: CCSwitchProviderRow,
        anthropicAvailable: Bool
    ) -> CCSwitchImportCandidate {
        let identity = "\(row.appType)|\(row.id)"
        let displayName = prefixedDisplayName(row.name)
        let extracted = CCSwitchCredentialExtractor.extract(
            appType: row.appType,
            name: row.name,
            settingsJSON: row.settingsConfig,
            metaJSON: row.meta
        )
        switch extracted {
        case .skip(let reasonKey):
            return CCSwitchImportCandidate(
                id: identity,
                sourceName: row.name,
                displayName: displayName,
                provider: .openAICompatible,
                baseURL: "",
                apiKey: "",
                appType: row.appType,
                skipReason: reasonKey
            )
        case .credentials(let baseURL, let apiKey, _):
            let trimmedURL = trimBaseURL(baseURL)
            guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else {
                return CCSwitchImportCandidate(
                    id: identity,
                    sourceName: row.name,
                    displayName: displayName,
                    provider: .openAICompatible,
                    baseURL: trimmedURL,
                    apiKey: apiKey,
                    appType: row.appType,
                    skipReason: skipMissingBaseURL
                )
            }
            if let mapped = mapProtocol(
                appType: row.appType,
                url: url,
                trimmedURL: trimmedURL,
                anthropicAvailable: anthropicAvailable
            ) {
                return CCSwitchImportCandidate(
                    id: identity,
                    sourceName: row.name,
                    displayName: displayName,
                    provider: mapped.provider,
                    baseURL: mapped.baseURL,
                    apiKey: apiKey,
                    appType: row.appType,
                    skipReason: nil
                )
            }
            return CCSwitchImportCandidate(
                id: identity,
                sourceName: row.name,
                displayName: displayName,
                provider: .openAICompatible,
                baseURL: trimmedURL,
                apiKey: apiKey,
                appType: row.appType,
                skipReason: skipUnsupported
            )
        }
    }

    private static func mapProtocol(
        appType: String,
        url: URL,
        trimmedURL: String,
        anthropicAvailable: Bool
    ) -> (provider: AIServiceProvider, baseURL: String)? {
        let path = url.path.lowercased()
        let isClaude = appType == "claude" || appType == "claude_desktop"
        let isAnthropicPath = path.contains("/anthropic")
        if anthropicAvailable, isClaude || isAnthropicPath {
            return (.anthropic, trimmedURL)
        }
        if let hostMapped = openAIProvider(for: url) {
            return hostMapped
        }
        if path.contains("/v1") || path.contains("/compatible-mode") || path.contains("/openai") {
            return (.openAICompatible, trimmedURL)
        }
        return nil
    }

    private static func openAIProvider(for url: URL) -> (AIServiceProvider, String)? {
        let host = (url.host ?? "").lowercased()
        let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let port = url.port ?? ((url.scheme?.lowercased() == "https") ? 443 : 80)

        if stripped == "localhost" || stripped == "127.0.0.1" {
            if port == 11434 { return (.ollama, AIServiceProvider.ollama.defaultBaseURL) }
            if port == 1234 { return (.lmStudio, AIServiceProvider.lmStudio.defaultBaseURL) }
        }

        let table: [(String, AIServiceProvider)] = [
            ("api.openai.com", .openAICompatible),
            ("api.deepseek.com", .deepSeek),
            ("openrouter.ai", .openRouter),
            ("integrate.api.nvidia.com", .nvidia),
            ("router.huggingface.co", .huggingface),
            ("api.mistral.ai", .mistral),
            ("ark.cn-beijing.volces.com", .doubao),
            ("api.x.ai", .grok),
            ("api.hunyuan.cloud.tencent.com", .hunyuan),
            ("api.moonshot.cn", .moonshot),
            ("api.moonshot.ai", .moonshot),
            ("dashscope.aliyuncs.com", .qianwen),
            ("api.siliconflow.cn", .siliconflow),
            ("apis.iflow.cn", .iflow),
            ("api-inference.modelscope.cn", .modelscope),
            ("open.bigmodel.cn", .zhipu),
            ("api.z.ai", .zai),
            ("api.orcarouter.ai", .orcaRouter),
            ("models.github.ai", .githubModels)
        ]
        for (candidate, provider) in table {
            if stripped == candidate || stripped.hasSuffix("." + candidate) {
                return (provider, provider.defaultBaseURL)
            }
        }
        return nil
    }

    private static func trimBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
