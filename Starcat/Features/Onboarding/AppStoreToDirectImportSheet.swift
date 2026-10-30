//
//  AppStoreToDirectImportSheet.swift
//  Starcat
//
//  Direct 第一次打开时的导入确认层。不是可随手关掉的 inspector：
//  没有 SheetCloseButton，Esc / 「不拷贝」才是拒绝路径。
//
//  布局对齐设置页「清空所有数据」确认 sheet：左图标 + 标题、范围列表、右下按钮。
//

import SwiftUI

struct AppStoreToDirectImportSheet: View {
    let isCopying: Bool
    let errorMessage: String?
    let onCopy: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            scopeList
            footnotes
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(24)
        .frame(width: 480)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text("launch.directImport.title")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("launch.directImport.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scopeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("launch.directImport.scope.title")
                .font(.headline)
                .foregroundStyle(.primary)

            ForEach(scopeItems, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "smallcircle.filled.circle")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey(item))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("launch.directImport.footnote.keepSource")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("launch.directImport.footnote.subscription")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("launch.directImport.skip", role: .cancel) {
                onSkip()
            }
            .disabled(isCopying)
            .keyboardShortcut(.cancelAction)

            Button {
                onCopy()
            } label: {
                if isCopying {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("launch.directImport.copying")
                    }
                } else {
                    Text("launch.directImport.copy")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCopying)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var scopeItems: [String] {
        [
            "launch.directImport.scope.credentials",
            "launch.directImport.scope.database",
            "launch.directImport.scope.caches",
            "launch.directImport.scope.settings"
        ]
    }
}
