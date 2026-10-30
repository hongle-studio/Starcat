//
//  GitLFS.swift
//  Starcat
//
//  Git LFS pointer 解析与 Batch API 契约。
//
//  为什么单独抽：git blob 对 LFS 跟踪的文件只返回 ~130 字节 pointer，不是真实内容。
//  勾选下载必须认出 pointer，再走 `POST .../info/lfs/objects/batch` 拿临时下载地址。
//  解析必须能单测，不能绑在 URLSession 上。
//

import Foundation

/// git blob 里的 LFS pointer。`oid` 是 64 位 hex，不含 `sha256:` 前缀。
struct GitLFSPointer: Equatable, Sendable {
    let oid: String
    let size: Int

    /// 只有整段内容符合 Git LFS spec 才返回；普通小文件不能误判。
    static func parse(_ data: Data) -> GitLFSPointer? {
        guard data.count <= 1024, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first,
              first == "version https://git-lfs.github.com/spec/v1" else {
            return nil
        }

        var oid: String?
        var size: Int?
        for line in lines.dropFirst() where !line.isEmpty {
            if line.hasPrefix("oid sha256:") {
                let hex = String(line.dropFirst("oid sha256:".count))
                guard hex.count == 64, hex.unicodeScalars.allSatisfy({ CharacterSet.hexadecimal.contains($0) }) else {
                    return nil
                }
                oid = hex
            } else if line.hasPrefix("size ") {
                guard let value = Int(line.dropFirst(5)), value >= 0 else { return nil }
                size = value
            }
        }
        guard let oid, let size else { return nil }
        return GitLFSPointer(oid: oid, size: size)
    }
}

enum GitLFSBatch {

    struct Request: Encodable {
        let operation = "download"
        let transfers = ["basic"]
        let objects: [Object]

        struct Object: Encodable {
            let oid: String
            let size: Int
        }
    }

    struct Response: Decodable {
        let objects: [Object]
    }

    struct Object: Decodable {
        let oid: String
        let size: Int?
        let error: ErrorPayload?
        let actions: Actions?
    }

    struct ErrorPayload: Decodable {
        let message: String?
    }

    struct Actions: Decodable {
        let download: Action?
    }

    struct Action: Decodable {
        let href: String
        let header: [String: String]?
    }

    /// GitHub LFS Batch 在 `github.com`，不是 `api.github.com`。
    static func batchURL(owner: String, repo: String) -> URL? {
        let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? owner
        let encodedRepo = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
        guard !encodedOwner.isEmpty, !encodedRepo.isEmpty else { return nil }
        return URL(string: "https://github.com/\(encodedOwner)/\(encodedRepo).git/info/lfs/objects/batch")
    }
}

private extension CharacterSet {
    static let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
}
