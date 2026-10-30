//
//  RepoLicenseOptionsPreferenceKey.swift
//  Starcat
//
//  非 Manage 列表把完整来源的许可证选项交回父级工具栏，不上传项目或逐行发请求。
//

import SwiftUI

/// 每个当前可见来源只发布完整缓存的规范值；离开来源后 SwiftUI 自动撤销旧 preference。
struct RepoLicenseOptionsPreferenceKey: PreferenceKey {
    static let defaultValue: [String] = []

    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value = Array(Set(value).union(nextValue())).sorted()
    }
}
