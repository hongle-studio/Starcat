//
//  LenientJSONArrayDecodingTests.swift
//  StarcatTests
//
//  覆盖「JSON 数组逐条解码」：单条失败不能让整表变 nil。
//

import Foundation
import Testing
@testable import Starcat

struct LenientJSONArrayDecodingTests {

    private struct Item: Codable, Equatable {
        var id: String
        var kind: Kind
    }

    private enum Kind: String, Codable {
        case known
    }

    @Test("合法条目保留，未知 enum 条目进入 unrecognized")
    func skipsUnknownEnumCases() throws {
        let data = Data("""
        [
          {"id":"ok","kind":"known"},
          {"id":"future","kind":"notShippedYet"}
        ]
        """.utf8)

        let outcome = LenientJSONArrayDecoding.decode(Item.self, from: data)
        #expect(outcome.topLevelFailure == nil)
        #expect(outcome.items == [Item(id: "ok", kind: .known)])
        #expect(outcome.skips.count == 1)
        #expect(outcome.skips[0].index == 1)
        #expect(outcome.unrecognizedFragments.count == 1)

        let encoded = try LenientJSONArrayDecoding.encode(
            items: outcome.items,
            unrecognizedFragments: outcome.unrecognizedFragments
        )
        let roundTrip = String(decoding: encoded, as: UTF8.self)
        #expect(roundTrip.contains("notShippedYet"))
        #expect(roundTrip.contains("\"id\":\"ok\"") || roundTrip.contains("\"id\" : \"ok\"") || roundTrip.contains("ok"))
    }

    @Test("顶层不是数组时记 topLevelFailure，不吞掉原始错误")
    func topLevelObjectIsFailure() {
        let data = Data(#"{"id":"not-an-array"}"#.utf8)
        let outcome = LenientJSONArrayDecoding.decode(Item.self, from: data)
        #expect(outcome.items.isEmpty)
        #expect(outcome.unrecognizedFragments.isEmpty)
        #expect(outcome.topLevelFailure != nil)
    }
}
