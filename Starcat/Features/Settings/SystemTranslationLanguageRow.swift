//
//  SystemTranslationLanguageRow.swift
//  Starcat
//
//  系统翻译语言管理 Sheet 的单行展示。
//

import SwiftUI
import Translation

/// 展示一个源语言相对于当前目标语言的就绪状态和下载入口。
struct SystemTranslationLanguageRow: View {
    let name: String
    let identifier: String
    let status: LanguageAvailability.Status
    let isPreparing: Bool
    let downloadDisabled: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(verbatim: identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            statusAndAction
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusAndAction: some View {
        if isPreparing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("settings.translation.system.status.preparing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch status {
            case .installed:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("settings.translation.system.status.ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .supported:
                HStack(spacing: 8) {
                    Text("settings.translation.system.status.downloadRequired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("settings.translation.system.action.download", action: onDownload)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(downloadDisabled)
                }
            case .unsupported:
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("settings.translation.system.status.unsupported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            @unknown default:
                Text("settings.translation.system.status.unsupported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
