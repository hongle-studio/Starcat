//
//  LenientJSONArrayDecoding.swift
//  Starcat
//
//  把「整表 JSON 数组」拆成逐条解码。
//
//  为什么需要：
//  - `JSONDecoder.decode([Profile].self)` 遇到数组里任意一条失败（未知 provider enum、
//    单条脏数据）会让整表变 nil。AppSettings 再落到默认 profile，看起来像服务商列表消失。
//  - Direct Debug / 新旧版本共用同一份 UserDefaults 时，新二进制写出的未知 `provider`
//    会让旧二进制解不出任何旧服务商。
//
//  关键约束：
//  - 解不出的条目以原始 JSON 片段留下，写回时拼回数组，禁止把未知服务商从磁盘抹掉。
//  - 顶层不是数组才算整表失败；单条失败只记 skip。
//

import Foundation

enum LenientJSONArrayDecoding {

    struct Skip: Equatable, Sendable {
        var index: Int
        var summary: String
    }

    struct Outcome<Element> {
        var items: [Element]
        var unrecognizedFragments: [Data]
        var skips: [Skip]
        var topLevelFailure: (any Error)?
    }

    static func decode<Element: Decodable>(
        _ type: Element.Type,
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) -> Outcome<Element> {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            return Outcome(items: [], unrecognizedFragments: [], skips: [], topLevelFailure: error)
        }
        guard let array = json as? [Any] else {
            let error = DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Expected a JSON array")
            )
            return Outcome(items: [], unrecognizedFragments: [], skips: [], topLevelFailure: error)
        }

        var items: [Element] = []
        var unrecognizedFragments: [Data] = []
        var skips: [Skip] = []
        items.reserveCapacity(array.count)

        for (index, value) in array.enumerated() {
            guard JSONSerialization.isValidJSONObject(value),
                  let fragment = try? JSONSerialization.data(withJSONObject: value)
            else {
                skips.append(
                    Skip(
                        index: index,
                        summary: DiagnosticEvent.summarize(
                            DecodingError.dataCorrupted(
                                .init(
                                    codingPath: [ArrayIndexKey(index)],
                                    debugDescription: "Array element is not a JSON object"
                                )
                            )
                        )
                    )
                )
                continue
            }
            do {
                items.append(try decoder.decode(Element.self, from: fragment))
            } catch {
                unrecognizedFragments.append(fragment)
                skips.append(Skip(index: index, summary: DiagnosticEvent.summarize(error)))
            }
        }

        return Outcome(
            items: items,
            unrecognizedFragments: unrecognizedFragments,
            skips: skips,
            topLevelFailure: nil
        )
    }

    /// 把已解码条目与跳过的原始 JSON 片段重新拼成数组。
    /// 无未知片段时走 `JSONEncoder` + sortedKeys，保持既有 UserDefaults 形态。
    static func encode<Element: Encodable>(
        items: [Element],
        unrecognizedFragments: [Data]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let recognizedData = try encoder.encode(items)
        guard !unrecognizedFragments.isEmpty else {
            return recognizedData
        }
        guard var array = try JSONSerialization.jsonObject(with: recognizedData) as? [Any] else {
            return recognizedData
        }
        for fragment in unrecognizedFragments {
            array.append(try JSONSerialization.jsonObject(with: fragment))
        }
        return try JSONSerialization.data(withJSONObject: array)
    }

    private struct ArrayIndexKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ index: Int) {
            stringValue = "Index \(index)"
            intValue = index
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = Int(stringValue)
        }

        init?(intValue: Int) {
            stringValue = "Index \(intValue)"
            self.intValue = intValue
        }
    }
}
