//
//  ScreensaverSharedConfiguration.swift
//  Starcat
//
//  Direct App 与 .saver 共用的快照文件布局。
//
//  关键约束：
//  - 不新增 App Group。新 group 需要改描述文件，当前 Direct Debug profile
//    还没有 `group.com.starcat.app.direct.screensaver`；
//  - Direct 主应用非沙箱，直接写 Application Support；
//  - `.saver` 跑在 `legacyScreenSaver` 里，`FileManager.homeDirectoryForCurrentUser`
//    会指向容器家目录。必须用 `getpwuid` 的真实 `$HOME`，否则读不到 App 写下的快照。
//

import CryptoKit
import Darwin
import Foundation

/// 解析屏保快照目录与固定文件名。
enum ScreensaverSharedConfiguration {
    static let snapshotFileName = "screensaver-snapshot-v1.json"
    static let avatarsDirectoryName = "avatars"
    static let relativeSupportPath = "Library/Application Support/com.starcat.app/screensaver"

    /// 生产快照根目录。`homeDirectory` 只给单测注入假家目录。
    static func productionContainerURL(homeDirectory: URL? = nil) -> URL {
        let home = homeDirectory ?? realHomeDirectoryURL()
        return home.appendingPathComponent(relativeSupportPath, isDirectory: true)
    }

    /// ScreenSaver 插件里的「家目录」是容器，不能拿去拼 Application Support。
    static func realHomeDirectoryURL() -> URL {
        if let password = getpwuid(getuid()), let dir = password.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func snapshotURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    static func avatarsDirectoryURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent(avatarsDirectoryName, isDirectory: true)
    }

    /// visualKey → 不可注入路径的稳定 PNG 名。App 写入与屏保读取必须同一套哈希。
    static func avatarFileName(visualKey: String) -> String {
        let digest = SHA256.hash(data: Data(visualKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }
}
