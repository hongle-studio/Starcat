//
//  RepoLicenseFilter.swift
//  Starcat
//
//  主窗口许可证多选的唯一匹配规则；数据库分页与内存派生必须使用同一归一化口径。
//

import Foundation

/// 空集合表示全部；集合内取 OR，与列表其它条件取 AND。未知只表示元数据不足，非法律结论。
struct RepoLicenseFilter: Hashable, Sendable {
    static let unknownKey = "__unknown__"
    static let all = RepoLicenseFilter()
    let selections: Set<String>

    /// 只映射明确同义的展示名称，不合并 GPL / LGPL / AGPL 或不同协议版本。
    private static let aliases = [
        "mit license": "mit",
        "apache license 2.0": "apache-2.0",
        "bsd 2-clause \"simplified\" license": "bsd-2-clause",
        "bsd 3-clause \"new\" or \"revised\" license": "bsd-3-clause",
        "mozilla public license 2.0": "mpl-2.0",
        "the unlicense": "unlicense",
    ]
    private static let commonKeys = ["mit", "apache-2.0", "bsd-3-clause", "bsd-2-clause", "mpl-2.0", "gpl-3.0", "agpl-3.0", "lgpl-3.0", "unlicense"]
    private static let names = [
        "mit": "MIT", "apache-2.0": "Apache-2.0", "bsd-2-clause": "BSD-2-Clause",
        "bsd-3-clause": "BSD-3-Clause", "mpl-2.0": "MPL-2.0", "unlicense": "Unlicense",
        "gpl-3.0": "GPL-3.0", "agpl-3.0": "AGPL-3.0", "lgpl-3.0": "LGPL-3.0",
    ]

    init(_ selections: [String] = []) {
        self.selections = Set(selections.map(Self.key))
    }

    var isActive: Bool { !selections.isEmpty }
    /// 排序后持久化 / 构造字符串身份，不让点击次序改变查询身份。
    var persistedValues: [String] { selections.sorted() }
    /// 长度前缀避免自定义协议文本含分隔符时发生查询身份碰撞。
    var cacheKey: String { persistedValues.map { "\($0.utf8.count):\($0)" }.joined() }

    func matches(_ license: String?) -> Bool {
        !isActive || selections.contains(Self.key(license))
    }

    /// ASCII 大小写与 SQLite LOWER 一致；保留自定义 Unicode 名称，不猜测协议。
    static func key(_ license: String?) -> String {
        let trimmed = (license ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        let lowered = String(decoding: trimmed.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
        if lowered.isEmpty || lowered == "noassertion" { return unknownKey }
        return aliases[lowered] ?? lowered
    }

    static func displayName(for key: String) -> String {
        names[key] ?? key
    }

    /// 完整来源值与已选值合并，筛选后即使没有匹配行，仍能取消原选择。
    static func options(_ values: [String?], including selected: RepoLicenseFilter = .all) -> [String] {
        let keys = Set(values.map(key)).union(selected.selections).union([unknownKey])
        return keys.sorted { lhs, rhs in
            let left = commonKeys.firstIndex(of: lhs) ?? commonKeys.count
            let right = commonKeys.firstIndex(of: rhs) ?? commonKeys.count
            return left == right ? lhs < rhs : left < right
        }
    }

    /// 列名只接受内部白名单；所有用户选择走绑定参数，不能拼进 SQL。
    enum Column: String { case repository = "r.license", weekly = "license_spdx" }

    /// 在 COUNT / LIMIT 之前执行，与 matches 共用同一组别名和未知值规则。
    func sqlPredicate(column: Column) -> (sql: String, arguments: [String])? {
        guard isActive else { return nil }
        let value = "lower(trim(COALESCE(\(column.rawValue), ''), ' ' || char(9) || char(13) || char(10)))"
        let cases = (["": Self.unknownKey, "noassertion": Self.unknownKey].merging(Self.aliases) { _, rhs in rhs })
            .sorted { $0.key < $1.key }
            .map { "WHEN '\($0.key.replacingOccurrences(of: "'", with: "''"))' THEN '\($0.value)'" }
            .joined(separator: " ")
        let placeholders = Array(repeating: "?", count: selections.count).joined(separator: ", ")
        return ("(CASE \(value) \(cases) ELSE \(value) END) IN (\(placeholders))", persistedValues)
    }
}
