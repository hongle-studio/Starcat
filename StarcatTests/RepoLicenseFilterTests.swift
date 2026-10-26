//
//  RepoLicenseFilterTests.swift
//  StarcatTests
//
//  许可证共享规则的契约测试：Swift 与 SQLite 必须对相同元数据给出相同结果。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("RepoLicenseFilter")
struct RepoLicenseFilterTests {
    @Test("多选 OR、明确别名及未知元数据，不合并协议家族或版本")
    func matchingContract() {
        let filter = RepoLicenseFilter([" MIT License ", "Apache-2.0"])
        #expect(filter == RepoLicenseFilter(["apache license 2.0", "MIT"]))
        #expect(filter.matches("\tMit\r\n"))
        #expect(filter.matches("Apache License 2.0"))
        #expect(!filter.matches("GPL-3.0"))
        #expect(!filter.matches(nil))
        #expect(RepoLicenseFilter.all.matches(nil))
        #expect(RepoLicenseFilter.all.matches("custom"))
        let unknown = RepoLicenseFilter([RepoLicenseFilter.unknownKey])
        for value: String? in [nil, "", " \t\r\n", "NOASSERTION"] {
            #expect(unknown.matches(value))
        }
        #expect(!unknown.matches("LicenseRef-Custom"))
        let gpl = RepoLicenseFilter(["GPL-3.0"])
        #expect(!gpl.matches("AGPL-3.0"))
        #expect(!gpl.matches("LGPL-3.0"))
        #expect(!gpl.matches("GPL-2.0"))
        #expect(!gpl.matches("GPL-3.0-only"))
    }

    @Test("稳定身份去重，与点击顺序无关且不因自定义分隔符碰撞")
    func identityAndCompleteOptions() {
        let first = RepoLicenseFilter(["MIT", "apache-2.0", "mit"])
        let second = RepoLicenseFilter(["Apache-2.0", "MIT License"])
        #expect(first.cacheKey == second.cacheKey)
        #expect(first.persistedValues == ["apache-2.0", "mit"])
        #expect(RepoLicenseFilter(["a:b", "c"]).cacheKey != RepoLicenseFilter(["a", "b:c"]).cacheKey)
        let options = RepoLicenseFilter.options(["MIT", "mit license", nil], including: RepoLicenseFilter(["Custom"]))
        #expect(Set(options) == ["mit", "custom", RepoLicenseFilter.unknownKey])
    }

    @Test("两种数据库列与内存匹配完全一致，用户值仅走绑定参数")
    func sqlMatchesMemory() throws {
        let queue = try DatabaseQueue()
        let values: [String?] = [nil, "", " NOASSERTION\n", "MIT", " mit license\t", "Apache License 2.0", "GPL-3.0", "GPL-3.0-only", "AGPL-3.0", "自定义", "x' OR 1=1 --"]
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE repos (id INTEGER PRIMARY KEY, license TEXT, license_spdx TEXT)")
            for (index, value) in values.enumerated() {
                try db.execute(sql: "INSERT INTO repos VALUES (?, ?, ?)", arguments: [index, value, value])
            }
            for selection in [["MIT", "Apache-2.0"], [RepoLicenseFilter.unknownKey], ["GPL-3.0"], ["自定义"], ["x' OR 1=1 --"]] {
                let filter = RepoLicenseFilter(selection)
                let expected = values.indices.filter { filter.matches(values[$0]) }
                for column in [RepoLicenseFilter.Column.repository, .weekly] {
                    let predicate = try #require(filter.sqlPredicate(column: column))
                    let actual = try Int.fetchAll(db, sql: "SELECT r.id FROM repos r WHERE \(predicate.sql) ORDER BY r.id", arguments: StatementArguments(predicate.arguments))
                    #expect(actual == expected)
                }
            }
        }
    }
}
