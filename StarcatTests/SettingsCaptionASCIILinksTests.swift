//
//  SettingsCaptionASCIILinksTests.swift
//  StarcatTests
//
//  锁住设置页 caption 的 URL 边界：中文句号不能被收成 IDN 域名。
//

import Foundation
import Testing
@testable import Starcat

@Suite("SettingsCaptionASCIILinks")
struct SettingsCaptionASCIILinksTests {

    @Test("中文句号后的汉字不能进 link")
    func ideographicFullStopIsNotPartOfURL() {
        let source = "官方 Base URL 为 https://api.anthropic.com。中转请保留 /anthropic 后缀，例如 https://api.deepseek.com/anthropic。"
        let attributed = SettingsCaptionASCIILinks.attributedString(from: source)
        let links = linkTargets(in: attributed)
        #expect(links == [
            URL(string: "https://api.anthropic.com")!,
            URL(string: "https://api.deepseek.com/anthropic")!
        ])
        #expect(!links.contains { $0.host?.contains("xn--") == true })
    }

    @Test("英文句点是句号，不是域名的一部分")
    func trailingEnglishPeriodIsNotPartOfURL() {
        let source = "Official Base URL is https://api.anthropic.com. Relays keep /anthropic."
        let links = linkTargets(in: SettingsCaptionASCIILinks.attributedString(from: source))
        #expect(links == [URL(string: "https://api.anthropic.com")!])
    }

    private func linkTargets(in attributed: AttributedString) -> [URL] {
        var urls: [URL] = []
        for run in attributed.runs {
            if let url = run.link, urls.last != url {
                urls.append(url)
            }
        }
        return urls
    }
}
