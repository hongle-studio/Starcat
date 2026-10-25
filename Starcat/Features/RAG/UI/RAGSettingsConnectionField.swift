//
//  RAGSettingsConnectionField.swift
//  Starcat
//
//  重排和索引存储共用的连接字段。标签使用统一宽度，输入框填充剩余空间，
//  不依赖外层 Grid 的跨列测量，不显示原生控件的第二份标签。
//

import SwiftUI

/// 只负责字段排版，绑定、密钥保存和连接测试仍由各自设置页管理。
struct RAGSettingsConnectionField: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    let titleKey: LocalizedStringKey
    @Binding var text: String
    var isSecure = false

    var body: some View {
        // 各行独立确定高度；长翻译在固定标签列内换行，不挤压输入框或撑高其他行。
        HStack(alignment: .center, spacing: 12) {
            Text(titleKey)
                .lineLimit(nil)
                .frame(width: interfaceScale.scaled(100), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if isSecure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .lineLimit(1)
            .multilineTextAlignment(.leading)
            .frame(minWidth: 0, maxWidth: .infinity)
            .accessibilityLabel(titleKey)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
