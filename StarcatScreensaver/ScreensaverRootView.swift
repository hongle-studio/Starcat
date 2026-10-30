//
//  ScreensaverRootView.swift
//  StarcatScreensaver
//
//  屏保根视图：纯黑底、无标题网格；空态只居中 Starcat 应用图标。
//

import AppKit
import SwiftUI

struct ScreensaverRootView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stableMetrics: AmbientGridMetrics?

    let viewModel: ScreensaverViewModel

    var body: some View {
        GeometryReader { proxy in
            let candidateMetrics = AmbientGridMetrics(size: proxy.size)
            let displayedMetrics = stableMetrics ?? candidateMetrics
            let candidateLayout = candidateMetrics.canConfigureScreensaver
                ? candidateMetrics.layout(displayScale: displayScale)
                : nil

            ZStack {
                Color.black.ignoresSafeArea()
                content(metrics: displayedMetrics)
            }
            .task(id: candidateLayout) {
                guard let candidateLayout else { return }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                stableMetrics = candidateMetrics
                viewModel.configure(layout: candidateLayout, reduceMotion: reduceMotion)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: reduceMotion) { _, newValue in
            viewModel.updateReduceMotion(newValue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starcat")
    }

    @ViewBuilder
    private func content(metrics: AmbientGridMetrics) -> some View {
        switch viewModel.state {
        case .idle, .loading:
            // 屏保每次启动都会经过瞬态加载；保持纯黑，避免应用图标在头像墙前闪现。
            Color.clear
        case .empty:
            ScreensaverEmptyIcon()
        case .loaded(let snapshots):
            ScreensaverGridView(
                snapshots: snapshots,
                metrics: metrics,
                changedSlotIDs: viewModel.changedSlotIDs,
                flipDuration: AmbientGridConfig.defaultFlipDuration,
                reduceMotion: reduceMotion
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

/// 无快照或 0 张卡时的低干扰空态：只有应用图标，不写说明文案。
private struct ScreensaverEmptyIcon: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 128, height: 128)
            .accessibilityHidden(true)
    }
}
