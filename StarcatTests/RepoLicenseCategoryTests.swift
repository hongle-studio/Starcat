//
//  RepoLicenseCategoryTests.swift
//  StarcatTests
//
//  展示分类的明确白名单契约；分类不得改变许可证匹配或猜测复合协议的法律含义。
//

import SwiftUI
import Testing
@testable import Starcat

/// 覆盖常见协议、版本后缀、未知值及误匹配边界，不把颜色当作商用许可判定。
@Suite("License chip categories")
struct RepoLicenseCategoryTests {
    @Test("明确宽松协议及现有别名", arguments: ["MIT", "mit license", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Unlicense"])
    func permissive(license: String) {
        #expect(RepoLicenseCategory.category(for: license) == .permissive)
    }

    @Test("弱 Copyleft 与版本后缀", arguments: ["MPL-2.0", "LGPL-2.0-only", "LGPL-2.1-or-later", "LGPL-3.0"])
    func weakCopyleft(license: String) {
        #expect(RepoLicenseCategory.category(for: license) == .weakCopyleft)
    }

    @Test("强 Copyleft 与版本后缀", arguments: ["GPL-1.0-only", "GPL-2.0", "GPL-3.0-only", "GPL-3.0-or-later"])
    func strongCopyleft(license: String) {
        #expect(RepoLicenseCategory.category(for: license) == .strongCopyleft)
    }

    @Test("网络 Copyleft 不混入 GPL", arguments: ["AGPL-3.0", "agpl-3.0-only", "AGPL-3.0-or-later"])
    func networkCopyleft(license: String) {
        #expect(RepoLicenseCategory.category(for: license) == .networkCopyleft)
    }

    @Test("未知、自定义、复合及带例外协议不推断", arguments: [nil, "", "NOASSERTION", "LicenseRef-MIT-Custom", "MIT OR GPL-3.0", "MIT AND Apache-2.0", "GPL-3.0-only WITH Classpath-exception-2.0", "AGPL-99.0"] as [String?])
    func unclassified(license: String?) {
        #expect(RepoLicenseCategory.category(for: license) == .unclassified)
    }

    @Test("系统语义色与已确认规则一致")
    func categoryPalette() {
        #expect(RepoLicenseCategory.permissive.color == .green)
        #expect(RepoLicenseCategory.weakCopyleft.color == .yellow)
        #expect(RepoLicenseCategory.strongCopyleft.color == .orange)
        #expect(RepoLicenseCategory.networkCopyleft.color == .red)
        #expect(RepoLicenseCategory.unclassified.color == .gray)
        #expect(!RepoLicenseFilter(["GPL-3.0-only"]).matches("GPL-3.0-or-later"))
    }
}
