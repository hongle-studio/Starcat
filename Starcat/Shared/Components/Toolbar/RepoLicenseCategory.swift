//
//  RepoLicenseCategory.swift
//  Starcat
//
//  许可证胶囊的展示分类；颜色仅辅助识别义务类型，不参与筛选，也不代表法律结论。
//

import SwiftUI

/// 只分类已明确识别的协议，不推断自定义名称、复合表达式或许可证例外的含义。
/// 分类参考 https://choosealicense.com/licenses/；具体使用仍以项目许可证原文为准。
enum RepoLicenseCategory: CaseIterable, Equatable {
    case permissive
    case weakCopyleft
    case strongCopyleft
    case networkCopyleft
    case unclassified

    /// 用完整标识白名单匹配，避免 LGPL/AGPL 被 `contains("gpl")` 误归为 GPL。
    /// `-only`/`-or-later` 只共享展示色，原始筛选 key 和不同版本仍保持独立。
    static func category(for license: String?) -> Self {
        switch RepoLicenseFilter.key(license) {
        case "mit", "apache-2.0", "bsd-2-clause", "bsd-3-clause", "isc", "unlicense":
            return .permissive
        case "mpl-2.0",
             "lgpl-2.0", "lgpl-2.0-only", "lgpl-2.0-or-later",
             "lgpl-2.1", "lgpl-2.1-only", "lgpl-2.1-or-later",
             "lgpl-3.0", "lgpl-3.0-only", "lgpl-3.0-or-later":
            return .weakCopyleft
        case "gpl-1.0", "gpl-1.0-only", "gpl-1.0-or-later",
             "gpl-2.0", "gpl-2.0-only", "gpl-2.0-or-later",
             "gpl-3.0", "gpl-3.0-only", "gpl-3.0-or-later":
            return .strongCopyleft
        case "agpl-3.0", "agpl-3.0-only", "agpl-3.0-or-later":
            return .networkCopyleft
        default:
            return .unclassified
        }
    }

    /// 使用系统自适应色，字号、底色透明度与选中态继续复用左侧标签外观。
    var color: Color {
        switch self {
        case .permissive: .green
        case .weakCopyleft: .yellow
        case .strongCopyleft: .orange
        case .networkCopyleft: .red
        case .unclassified: .gray
        }
    }

    /// 分类仅放进悬停和辅助功能说明，不增加胶囊宽度或改变布局。
    var helpKey: LocalizedStringKey {
        switch self {
        case .permissive: "list.filter.license.category.permissive"
        case .weakCopyleft: "list.filter.license.category.weakCopyleft"
        case .strongCopyleft: "list.filter.license.category.strongCopyleft"
        case .networkCopyleft: "list.filter.license.category.networkCopyleft"
        case .unclassified: "list.filter.license.category.unclassified"
        }
    }
}
