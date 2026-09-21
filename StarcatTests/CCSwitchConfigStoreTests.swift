//
//  CCSwitchConfigStoreTests.swift
//  StarcatTests
//
//  用临时 sqlite fixture 与假 SQL dump 覆盖只读解析；非法文件视为不是 CC Switch 库。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("CCSwitchConfigStore")
struct CCSwitchConfigStoreTests {
    @Test("最小合法 sqlite 读出 2 行")
    func sqliteTwoRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-switch-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try DatabaseQueue(path: url.path)
        try db.write { database in
            try database.execute(sql: """
                CREATE TABLE providers (
                    id TEXT NOT NULL,
                    app_type TEXT NOT NULL,
                    name TEXT,
                    settings_config TEXT,
                    meta TEXT,
                    PRIMARY KEY (id, app_type)
                )
                """)
            try database.execute(
                sql: "INSERT INTO providers (id, app_type, name, settings_config, meta) VALUES (?, ?, ?, ?, ?)",
                arguments: ["a", "claude", "DeepSeek", "{\"env\":{}}", "{}"]
            )
            try database.execute(
                sql: "INSERT INTO providers (id, app_type, name, settings_config, meta) VALUES (?, ?, ?, ?, ?)",
                arguments: ["b", "codex", "MiniMax", "{\"auth\":{}}", "{}"]
            )
        }

        let rows = try CCSwitchConfigStore.open(url: url)
        #expect(rows.count == 2)
        #expect(rows.map(\.name).sorted() == ["DeepSeek", "MiniMax"])
    }

    @Test("空文件、PNG 头、缺表都不是 CC Switch 数据库")
    func invalidFiles() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-switch-empty-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty)
        #expect(throws: CCSwitchConfigStoreError.notCCSwitch) {
            _ = try CCSwitchConfigStore.open(url: empty)
        }

        let png = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-switch-png-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: png)
        #expect(throws: CCSwitchConfigStoreError.notCCSwitch) {
            _ = try CCSwitchConfigStore.open(url: png)
        }

        let missingTable = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-switch-other-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: missingTable) }
        let db = try DatabaseQueue(path: missingTable.path)
        try db.write { database in
            try database.execute(sql: "CREATE TABLE other (id TEXT)")
        }
        #expect(throws: CCSwitchConfigStoreError.notCCSwitch) {
            _ = try CCSwitchConfigStore.open(url: missingTable)
        }
    }

    @Test("SQL dump 含一条 INSERT providers 能读出 name")
    func sqlDumpInsert() throws {
        let sql = """
        INSERT INTO providers VALUES('deepseek','claude','DeepSeek','{"env":{"ANTHROPIC_AUTH_TOKEN":"sk-test-xxxx"}}',NULL,NULL,0,0,NULL,NULL,NULL,'{}',0,0);
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-switch-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: url) }
        try sql.write(to: url, atomically: true, encoding: .utf8)
        let rows = try CCSwitchConfigStore.open(url: url)
        #expect(rows.first?.name == "DeepSeek")
        #expect(rows.first?.appType == "claude")
    }
}
