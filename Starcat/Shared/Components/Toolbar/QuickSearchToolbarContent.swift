//
//  QuickSearchToolbarContent.swift
//  Starcat
//
//  主窗口中栏顶栏的折叠式快速搜索控件。
//

import SwiftUI

/// 复用已验收的搜索按钮、展开动画、输入框和关闭按钮，并让展开态独占整行顶栏。
struct QuickSearchToolbarContent<CollapsedContent: View>: View {
    @Binding var isExpanded: Bool
    @Binding var draft: String

    let committedQuery: String
    let placeholder: LocalizedStringKey
    let onSubmit: (String) -> Void
    let onClear: () -> Void
    @ViewBuilder let collapsedContent: () -> CollapsedContent

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isExpanded {
                searchField
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                searchButton
                collapsedContent()
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                isFocused = false
            }
        }
    }

    /// 折叠态保持 28×24pt 的已验收尺寸，避免搜索图标再次抢过排序和同步控件。
    private var searchButton: some View {
        Button(action: expand) {
            Image(systemName: "magnifyingglass")
                .font(SyncIconButton.defaultFont)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                }
                .contentShape(Rectangle())
                .accessibilityLabel(Text("list.quickSearch.open"))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(Text("list.quickSearch.open"))
    }

    /// Return 只提交草稿，不折叠；Esc 与关闭按钮都清空查询并恢复原顶栏。
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(SyncIconButton.defaultFont)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { onSubmit(draft) }
                .onExitCommand(perform: collapse)

            Button(action: collapse) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.32))
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
                .accessibilityLabel(Text("general.close"))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help(Text("general.close"))
        }
        .padding(.horizontal, 10)
        .frame(
            maxWidth: .infinity,
            minHeight: ManageListFilterBarMetrics.controlHeight,
            maxHeight: ManageListFilterBarMetrics.controlHeight
        )
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
    }

    private func expand() {
        draft = committedQuery
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isExpanded = true
        }

        // 输入框先进入视图树，下一轮主线程再取焦点，避免展开首帧吞掉键盘输入。
        Task { @MainActor in
            await Task.yield()
            isFocused = true
        }
    }

    private func collapse() {
        isFocused = false
        draft = ""
        onClear()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isExpanded = false
        }
    }
}
