//
//  AIOrganizationBannerText.swift
//  Starcat
//
//  本次新增横幅文案的局部源语言兜底；不修改全局本地化或翻译批准流程。
//

import Foundation

/// 英语源仅保护运行时资源缺失；新增文案仍必须补齐全部支持语言，不能以兜底代替覆盖校验。
enum AIOrganizationBannerText {
    private static let sourceBundle = Bundle.main.path(forResource: "en", ofType: "lproj")
        .flatMap { Bundle(path: $0) }

    static func l10n(_ key: String) -> String {
        resolve(String.l10n(key), for: key)
    }

    /// 强制语言子 bundle 缺译会原样返回 key；只替换这一种情况，已有翻译一律保留。
    static func resolve(_ localized: String, for key: String) -> String {
        guard localized == key else { return localized }
        return sourceBundle?.localizedString(forKey: key, value: nil, table: nil) ?? localized
    }
}
