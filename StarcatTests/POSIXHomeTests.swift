//
//  POSIXHomeTests.swift
//  StarcatTests
//
//  真实家目录不能落在 App Store 沙盒容器路径。
//

import Foundation
import Testing
@testable import Starcat

@Suite("POSIXHome")
struct POSIXHomeTests {
    @Test("家目录是真实 POSIX 路径且不含 Containers")
    func realHomePath() throws {
        let directory = try #require(POSIXHome.directory)
        let path = directory.path
        #expect(path.hasPrefix("/Users/") || path.hasPrefix("/var/") || path.hasPrefix("/private/var/"))
        #expect(!path.contains("/Library/Containers/"))
        if let database = POSIXHome.ccSwitchDefaultDatabase {
            #expect(database.path.hasSuffix("/.cc-switch/cc-switch.db"))
            #expect(!database.path.contains("/Library/Containers/"))
        }
    }
}
