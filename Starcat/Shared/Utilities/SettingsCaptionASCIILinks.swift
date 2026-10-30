//
//  SettingsCaptionASCIILinks.swift
//  Starcat
//
//  设置页 caption 里的 URL 必须按 ASCII 精确收成 link。
//
//  为什么不用 `Text("key")`：LocalizedStringKey 会按 Markdown 自动识别 URL，
//  并把中文句号 `。` 当成 IDN 的 `.`。`https://api.anthropic.com。中转` 点开会变成
//  `https://api.anthropic.com.xn--...`，官方域名被拼进乱码。
//

import SwiftUI

enum SettingsCaptionASCIILinks {

    /// 句号、逗号等是中英文 caption 的句读，不能算进 URL。
    private static let trailingPunctuation = Set(".,;:!?")

    /// 只匹配 ASCII `http(s)://`。故意不含 `\s` 和 CJK，这样 `。中转` 会截断匹配。
    private static let asciiURLPattern = #"https?://[A-Za-z0-9][A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*"#

    static func attributedString(from source: String) -> AttributedString {
        var attributed = AttributedString(source)
        attributed.foregroundColor = Color.secondary
        guard let regex = try? NSRegularExpression(pattern: asciiURLPattern) else {
            return attributed
        }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in regex.matches(in: source, range: nsRange) {
            guard var stringRange = Range(match.range, in: source) else { continue }
            var raw = String(source[stringRange])
            while let last = raw.last, trailingPunctuation.contains(last) {
                raw.removeLast()
                stringRange = stringRange.lowerBound..<source.index(before: stringRange.upperBound)
            }
            guard let url = URL(string: raw), url.host?.isEmpty == false else { continue }
            guard let start = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let end = AttributedString.Index(stringRange.upperBound, within: attributed)
            else {
                continue
            }
            attributed[start..<end].link = url
            attributed[start..<end].foregroundColor = Color.accentColor
        }
        return attributed
    }
}
