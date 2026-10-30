//
//  LinuxDoSourceBadge.swift
//  Starcat
//
//  来源事实与 Weekly/Activity 当前场景徽章并列显示。列表是纯本地标识，只有详情点击才加载帖子。
//

import SwiftUI

/// 列表只展示来源；详情点击直接打开最新讨论，不再插入二次选择弹窗。
struct LinuxDoSourceBadge: View {
    let repoID: Int64
    var interactive = false
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.openURL) private var openURL
    @State private var isOpeningDiscussion = false
    @State private var openingFailed = false

    var body: some View {
        if dependencies.linuxDoStore.origin(for: repoID) != nil {
            Group {
                if interactive {
                    Button {
                        openingFailed = false
                        isOpeningDiscussion = true
                    } label: { badge }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .disabled(isOpeningDiscussion)
                        .task(id: isOpeningDiscussion) {
                            await openDiscussion()
                        }
                        .onChange(of: repoID) {
                            isOpeningDiscussion = false
                            openingFailed = false
                        }
                        .onDisappear { isOpeningDiscussion = false }
                } else { badge }
            }
            .help(Text(openingFailed ? "linuxdo.cache.unavailable" : "linuxdo.source.help"))
            .accessibilityLabel(Text("linuxdo.source.help"))
        }
    }

    /// 生命周期任务防止切换仓库后迟到的请求打开旧帖子；请求期间禁止重复点击。
    private func openDiscussion() async {
        guard isOpeningDiscussion else { return }
        defer { if !Task.isCancelled { isOpeningDiscussion = false } }
        let url = await dependencies.linuxDoStore.discussionURL(for: repoID)
        guard !Task.isCancelled else { return }
        guard let url else {
            openingFailed = true
            return
        }
        openURL(url)
    }

    private var badge: some View {
        Text(verbatim: "Linux.do")
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary.opacity(0.35), in: Capsule())
            .fixedSize()
    }
}
