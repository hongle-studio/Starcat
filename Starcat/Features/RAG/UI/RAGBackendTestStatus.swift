//
//  RAGBackendTestStatus.swift
//  Starcat
//
//  知识库外部检索后端的连接状态模型，供后端配置与索引状态复用。
//

import SwiftUI

/// 「测试并保存」的分行状态。图标颜色表达结果，正文保持 `.secondary`。
enum RAGBackendTestStatus: Equatable {
    case success
    case rebuildRequired
    case failure(String)

    /// DESIGN.md `success` / `warning` / `danger`。状态色只用于图标和必要的状态信号。
    static let successTint = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let warningTint = Color(red: 255 / 255, green: 149 / 255, blue: 0 / 255)
    static let dangerTint = Color(red: 255 / 255, green: 59 / 255, blue: 48 / 255)

    var message: String {
        switch self {
        case .success:
            return String.l10n("settings.rag.backends.connectionSuccess")
        case .rebuildRequired:
            return String.l10n("settings.rag.backends.rebuildRequired")
        case .failure(let message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .rebuildRequired: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .success: return Self.successTint
        case .rebuildRequired: return Self.warningTint
        case .failure: return Self.dangerTint
        }
    }
}
