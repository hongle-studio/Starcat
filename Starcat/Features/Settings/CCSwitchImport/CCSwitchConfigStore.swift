//
//  CCSwitchConfigStore.swift
//  Starcat
//
//  只读打开 CC Switch 的 sqlite 或官方 SQL 备份，抽出 `providers` 行。
//
//  关键约束：
//  - 绝不写入外部库，也不改 `is_current`。
//  - 只 SELECT 需要的列；表不存在视为「不是 CC Switch 数据库」。
//  - SQL dump 只认 `INSERT INTO providers`，解析失败提示改选 `.db`。
//

import Foundation
import GRDB

/// CC Switch `providers` 表的最小行。`settingsConfig` / `meta` 保持原文，后续再 JSON 解析。
struct CCSwitchProviderRow: Equatable, Sendable {
    var id: String
    var appType: String
    var name: String
    var settingsConfig: String
    var meta: String?
}

enum CCSwitchConfigStoreError: Error, LocalizedError, Equatable {
    case notCCSwitch
    case openFailed

    var errorDescription: String? {
        switch self {
        case .notCCSwitch:
            return String.l10n("settings.ai.provider.importCCSwitch.error.notCCSwitch")
        case .openFailed:
            return String.l10n("settings.ai.provider.importCCSwitch.error.openFailed")
        }
    }
}

enum CCSwitchConfigStore {
    private static let sqliteMagic = "SQLite format 3\u{0}"

    static func open(url: URL) throws -> [CCSwitchProviderRow] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CCSwitchConfigStoreError.openFailed
        }
        defer { try? handle.close() }

        let header = handle.readData(ofLength: 16)
        if header.count >= 16, let magic = String(data: header, encoding: .utf8), magic == sqliteMagic {
            return try openSQLite(url: url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CCSwitchConfigStoreError.openFailed
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CCSwitchConfigStoreError.notCCSwitch
        }
        return try parseSQLDump(text)
    }

    private static func openSQLite(url: URL) throws -> [CCSwitchProviderRow] {
        var configuration = Configuration()
        configuration.readonly = true
        let db: DatabaseQueue
        do {
            db = try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw CCSwitchConfigStoreError.openFailed
        }

        do {
            return try db.read { database in
                guard try database.tableExists("providers") else {
                    throw CCSwitchConfigStoreError.notCCSwitch
                }
                let rows = try Row.fetchAll(
                    database,
                    sql: "SELECT id, app_type, name, settings_config, meta FROM providers"
                )
                return rows.map { row in
                    CCSwitchProviderRow(
                        id: row["id"] ?? "",
                        appType: row["app_type"] ?? "",
                        name: row["name"] ?? "",
                        settingsConfig: row["settings_config"] ?? "",
                        meta: row["meta"]
                    )
                }
            }
        } catch let error as CCSwitchConfigStoreError {
            throw error
        } catch {
            throw CCSwitchConfigStoreError.notCCSwitch
        }
    }

    /// 最小 SQL dump 解析：只提取 `INSERT INTO providers` 的 VALUES。
    static func parseSQLDump(_ text: String) throws -> [CCSwitchProviderRow] {
        let columns = ["id", "app_type", "name", "settings_config", "website_url", "category",
                       "created_at", "sort_index", "notes", "icon", "icon_color", "meta",
                       "is_current", "in_failover_queue"]
        var rows: [CCSwitchProviderRow] = []
        var search = text[...]
        let pattern = "INSERT INTO"
        while let range = search.range(of: pattern, options: [.caseInsensitive]) {
            let rest = search[range.upperBound...]
            guard let tableRange = rest.range(of: #"\s+(?:providers|"providers"|`providers`)"#, options: [.regularExpression, .caseInsensitive]) else {
                search = rest
                continue
            }
            var cursor = rest[tableRange.upperBound...]
            var columnOrder = columns
            cursor = cursor.drop(while: { $0.isWhitespace || $0 == "\n" || $0 == "\r" })
            if cursor.first == "(" {
                let list = String(cursor)
                if let close = matchingParenEnd(list) {
                    let inner = String(list.dropFirst().prefix(close - 1))
                    let names = inner.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]"))
                    }
                    if !names.isEmpty {
                        columnOrder = names
                    }
                    cursor = list.dropFirst(close + 1)[...]
                }
            }
            guard let valuesRange = cursor.range(of: "VALUES", options: [.caseInsensitive]) else {
                search = rest
                continue
            }
            var valuesCursor = cursor[valuesRange.upperBound...]
            while true {
                valuesCursor = valuesCursor.drop(while: { $0.isWhitespace || $0 == "\n" || $0 == "\r" || $0 == "," })
                guard valuesCursor.first == "(" else { break }
                let payload = String(valuesCursor)
                guard let end = matchingParenEnd(payload) else {
                    throw CCSwitchConfigStoreError.notCCSwitch
                }
                let tuple = String(payload.dropFirst().prefix(end - 1))
                let values = parseSQLValueList(tuple)
                if let row = makeRow(columns: columnOrder, values: values) {
                    rows.append(row)
                }
                valuesCursor = payload.dropFirst(end + 1)[...]
                let trimmed = valuesCursor.drop(while: { $0.isWhitespace || $0 == "\n" || $0 == "\r" })
                if trimmed.first == ";" { break }
            }
            search = rest
        }
        guard !rows.isEmpty else {
            throw CCSwitchConfigStoreError.notCCSwitch
        }
        return rows
    }

    private static func matchingParenEnd(_ text: String) -> Int? {
        var depth = 0
        var inString = false
        var i = text.startIndex
        var offset = 0
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if ch == "'" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "'" {
                        i = text.index(after: next)
                        offset += 2
                        continue
                    }
                    inString = false
                }
            } else if ch == "'" {
                inString = true
            } else if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 {
                    return offset
                }
            }
            i = text.index(after: i)
            offset += 1
        }
        return nil
    }

    private static func parseSQLValueList(_ text: String) -> [String?] {
        var values: [String?] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace || text[i] == "\n" || text[i] == "\r" || text[i] == "," {
                i = text.index(after: i)
            }
            guard i < text.endIndex else { break }
            if text[i] == "'" {
                i = text.index(after: i)
                var value = ""
                while i < text.endIndex {
                    if text[i] == "'" {
                        let next = text.index(after: i)
                        if next < text.endIndex, text[next] == "'" {
                            value.append("'")
                            i = text.index(after: next)
                            continue
                        }
                        i = next
                        break
                    }
                    value.append(text[i])
                    i = text.index(after: i)
                }
                values.append(value)
            } else {
                var token = ""
                while i < text.endIndex, text[i] != "," {
                    token.append(text[i])
                    i = text.index(after: i)
                }
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                values.append(trimmed.uppercased() == "NULL" ? nil : trimmed)
            }
        }
        return values
    }

    private static func makeRow(columns: [String], values: [String?]) -> CCSwitchProviderRow? {
        func value(_ name: String) -> String {
            guard let index = columns.firstIndex(of: name), index < values.count else { return "" }
            return values[index] ?? ""
        }
        func optionalValue(_ name: String) -> String? {
            guard let index = columns.firstIndex(of: name), index < values.count else { return nil }
            return values[index]
        }
        let id = value("id")
        let appType = value("app_type")
        let name = value("name")
        guard !id.isEmpty || !name.isEmpty else { return nil }
        return CCSwitchProviderRow(
            id: id,
            appType: appType,
            name: name,
            settingsConfig: value("settings_config"),
            meta: optionalValue("meta")
        )
    }
}
