//
//  SystemTranslationLanguageCatalog.swift
//  Starcat
//
//  系统翻译语言目录：读取 Apple Translation 支持的语言，并按当前目标语言检查
//  每个源语言组合是否已经下载就绪。
//
//  关键约束：
//  - `LanguageAvailability` 暴露的是语言组合状态，不是系统语言包文件清单；
//  - 状态只用于设置页展示，不写入本地持久化，因为用户或系统可随时删除语言包；
//  - 本目录不持有 `TranslationSession`，避免干扰 README 正在使用的系统翻译会话。
//

import Foundation
import Observation
// macOS 26 SDK 的 LanguageAvailability 尚未标注 Sendable；目录始终由 MainActor
// 串行访问，因此沿用项目现有 Translation 兼容方式，避免伪造跨线程安全声明。
@preconcurrency import Translation

/// 设置页共享的系统翻译语言状态快照。
@MainActor
@Observable
final class SystemTranslationLanguageCatalog {
    private(set) var languages: [Locale.Language] = []
    private(set) var statuses: [String: LanguageAvailability.Status] = [:]
    private(set) var isRefreshing = false
    private(set) var targetIdentifier: String?

    /// 异步刷新可重入；generation 防止旧目标语言的迟到结果覆盖新结果。
    private var refreshGeneration = 0

    var readyCount: Int {
        statuses.values.count(where: { $0 == .installed })
    }

    var availablePairCount: Int {
        statuses.values.count(where: { $0 != .unsupported })
    }

    func status(for language: Locale.Language) -> LanguageAvailability.Status? {
        statuses[Self.identifier(for: language)]
    }

    func isLoaded(for target: ReadmeTranslationLanguage) -> Bool {
        targetIdentifier == Self.identifier(for: target.resolved().localeLanguage)
    }

    /// 重新读取 Apple Translation 的实时状态。
    ///
    /// 状态不缓存到磁盘：语言包由系统在所有 App 间共享，可能在 Starcat 运行期间
    /// 被下载或删除，持久化旧结果反而会误导用户。
    func refresh(
        target: ReadmeTranslationLanguage,
        force: Bool = false
    ) async {
        let resolvedTarget = target.resolved().localeLanguage
        let resolvedTargetIdentifier = Self.identifier(for: resolvedTarget)
        if !force,
           targetIdentifier == resolvedTargetIdentifier,
           !languages.isEmpty {
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        defer {
            if generation == refreshGeneration {
                isRefreshing = false
            }
        }

        let availability = LanguageAvailability()
        let supportedLanguages = await availability.supportedLanguages
        var nextLanguages: [Locale.Language] = []
        var nextStatuses: [String: LanguageAvailability.Status] = [:]

        for source in supportedLanguages {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            // Apple 不支持同语种变体互译；目标语言本身也不应显示成可下载源语言。
            guard !Self.representsSameLanguage(source, resolvedTarget) else { continue }

            let status = await availability.status(from: source, to: resolvedTarget)
            let identifier = Self.identifier(for: source)
            nextLanguages.append(source)
            nextStatuses[identifier] = status
        }

        guard !Task.isCancelled, generation == refreshGeneration else { return }
        languages = nextLanguages
        statuses = nextStatuses
        targetIdentifier = resolvedTargetIdentifier
    }

    private static func representsSameLanguage(
        _ source: Locale.Language,
        _ target: Locale.Language
    ) -> Bool {
        if let sourceCode = source.languageCode,
           let targetCode = target.languageCode {
            return sourceCode == targetCode
        }
        return identifier(for: source) == identifier(for: target)
    }

    private static func identifier(for language: Locale.Language) -> String {
        language.minimalIdentifier
    }
}
