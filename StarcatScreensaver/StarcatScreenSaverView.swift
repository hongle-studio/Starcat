//
//  StarcatScreenSaverView.swift
//  StarcatScreensaver
//
//  ScreenSaver.framework 入口。只托管 SwiftUI 网格，动画由 ViewModel 的 deadline
//  调度，不走 ScreenSaverView.animateOneFrame 的帧循环。
//

import AppKit
import ScreenSaver
import SwiftUI

/// 系统屏保进程加载的 principal class。
///
/// Info.plist 必须写 `StarcatScreensaver.StarcatScreenSaverView`（模块名.类名）。
/// Swift 屏保若只写裸类名，系统会提示与当前 macOS 不兼容并直接从列表里丢掉。
@objc(StarcatScreenSaverView)
final class StarcatScreenSaverView: ScreenSaverView {
    private var hostingView: NSHostingView<ScreensaverRootView>?
    private let viewModel = ScreensaverViewModel()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 0
        configureBacking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 0
        configureBacking()
    }

    override func startAnimation() {
        super.startAnimation()
        viewModel.setActive(true)
    }

    override func stopAnimation() {
        viewModel.setActive(false)
        super.stopAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installRootViewIfNeeded()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        hostingView?.frame = bounds
    }

    private func configureBacking() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        installRootViewIfNeeded()
    }

    private func installRootViewIfNeeded() {
        guard hostingView == nil else {
            hostingView?.frame = bounds
            return
        }
        let root = ScreensaverRootView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }
}
