//
//  POSIXHome.swift
//  Starcat
//
//  真实用户家目录。App Store 沙盒下 `NSHomeDirectory()` / `FileManager.homeDirectoryForCurrentUser`
//  会指向容器，不能拿去提示用户找 `~/.cc-switch/cc-switch.db`。
//
//  关键约束：只用 `getpwuid(getuid())` 的 `pw_dir`。
//

import Darwin
import Foundation

enum POSIXHome {
    /// 当前用户的 POSIX 家目录。失败时返回 nil，调用方再降级到文件选择器。
    static var directory: URL? {
        guard let password = getpwuid(getuid()) else { return nil }
        let dir = password.pointee.pw_dir
        guard let dir else { return nil }
        let path = String(cString: dir)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// CC Switch 默认数据库路径。仅用于 Direct 探测与 App Store 选择器文案。
    static var ccSwitchDefaultDatabase: URL? {
        directory?
            .appendingPathComponent(".cc-switch", isDirectory: true)
            .appendingPathComponent("cc-switch.db")
    }
}
