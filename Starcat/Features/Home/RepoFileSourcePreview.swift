//
//  RepoFileSourcePreview.swift
//  Starcat
//
//  下载文件 Sheet 中栏的源码预览。只读 NSTextView + 行号标尺，不要用 SwiftUI Text 逐行拼。
//
//  为什么不用 SwiftUI：
//  - `ScrollView([.horizontal, .vertical])` + `LazyVStack` + `Text.frame(maxWidth: .infinity)`
//    会把每一行当成段落按列宽折行。CJK 没有空格分词，看起来像原文被撕碎；
//  - 双向 ScrollView 里的 LazyVStack 也不会按「源码一行 = 视图一行」布局。
//  NSTextView 是 TextEdit / 系统文本的同一套排版：按容器宽度折行、跨行选择、原生滚动条。
//  行号画在 NSRulerView 上，只给每个源码行的首个 line fragment 标号，折行不重复编号。
//

import AppKit
import SwiftUI

struct RepoFileSourcePreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.focusRingType = .none

        let textView = RepoFilePreviewTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.font = Self.previewFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.string = text

        scrollView.documentView = textView

        let ruler = RepoFileLineNumberRulerView(textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.verticalRulerView = ruler
        context.coordinator.observe(scrollView: scrollView, ruler: ruler)
        ruler.recalculateThickness()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            let upperBound = (text as NSString).length
            textView.selectedRanges = selectedRanges.map { value in
                let range = value.rangeValue
                let location = min(range.location, upperBound)
                let length = min(range.length, max(upperBound - location, 0))
                return NSValue(range: NSRange(location: location, length: length))
            }
        }
        textView.font = Self.previewFont
        textView.textColor = .labelColor
        (scrollView.verticalRulerView as? RepoFileLineNumberRulerView)?.recalculateThickness()
        scrollView.verticalRulerView?.needsDisplay = true
    }

    func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static let previewFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// 滚动和窗口缩放都会改 line fragment，标尺必须跟着重绘。
    ///
    /// 挂 `@MainActor`：NSViewRepresentable 的生命周期回调全部在主线程，
    /// Coordinator 与 makeNSView / dismantleNSView 同处主隔离域，可直接触碰 AppKit 视图。
    @MainActor
    final class Coordinator {
        private var observations: [NSObjectProtocol] = []

        func observe(scrollView: NSScrollView, ruler: NSRulerView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            // `using:` 要求 @Sendable 闭包，不能直接捕获非 Sendable 的 AppKit 视图；
            // `queue: .main` 保证回调落在主线程，进 MainActor.assumeIsolated 再触发重绘。
            let redraw: @Sendable (Notification) -> Void = { [weak ruler] _ in
                MainActor.assumeIsolated {
                    ruler?.needsDisplay = true
                }
            }
            observations = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main, using: redraw),
                center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main, using: redraw),
                center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.documentView, queue: .main, using: redraw)
            ]
        }

        func disconnect() {
            let center = NotificationCenter.default
            observations.forEach { center.removeObserver($0) }
            observations.removeAll()
        }
    }
}

/// Cmd+F 仍交给 Sheet 顶栏搜文件树；不要弹出 NSTextView 的查找栏。
private final class RepoFilePreviewTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 只给源码物理行的第一个 fragment 画行号；软折行不另起编号。
private final class RepoFileLineNumberRulerView: NSRulerView {
    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func recalculateThickness() {
        let textView = clientView as? NSTextView
        let lineCount = max(1, lineCount(in: textView?.string ?? ""))
        let digits = max(2, String(lineCount).count)
        let width = CGFloat(digits) * 8 + 18
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView = clientView as? NSTextView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return }

        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSBezierPath.fill(NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height))

        let text = textView.string as NSString
        let inset = textView.textContainerInset
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        if text.length == 0 {
            drawNumber(1, attributes: attributes, in: NSRect(x: 0, y: inset.height, width: ruleThickness, height: 16))
            return
        }

        var lineNumber = 1
        if glyphRange.location > 0 {
            let firstChar = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            text.enumerateSubstrings(
                in: NSRange(location: 0, length: firstChar),
                options: [.byLines, .substringNotRequired]
            ) { _, _, enclosing, _ in
                if NSMaxRange(enclosing) <= firstChar {
                    lineNumber += 1
                }
            }
        }

        var glyphIndex = glyphRange.location
        let glyphEnd = NSMaxRange(glyphRange)
        while glyphIndex < glyphEnd {
            var fragmentGlyphRange = NSRange()
            let fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &fragmentGlyphRange,
                withoutAdditionalLayout: true
            )
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let sourceLineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            if charIndex == sourceLineRange.location {
                let y = convert(NSPoint(x: 0, y: fragmentRect.minY + inset.height), from: textView).y
                drawNumber(
                    lineNumber,
                    attributes: attributes,
                    in: NSRect(x: 0, y: y, width: ruleThickness - 8, height: fragmentRect.height)
                )
                lineNumber += 1
            }
            glyphIndex = NSMaxRange(fragmentGlyphRange)
        }

        let extra = layoutManager.extraLineFragmentUsedRect
        if extra.height > 0 {
            let extraMinY = extra.minY + inset.height
            if extraMinY + extra.height > visibleRect.minY, extraMinY < visibleRect.maxY {
                let y = convert(NSPoint(x: 0, y: extraMinY), from: textView).y
                drawNumber(
                    lineNumber,
                    attributes: attributes,
                    in: NSRect(x: 0, y: y, width: ruleThickness - 8, height: extra.height)
                )
            }
        }
    }

    private func drawNumber(_ number: Int, attributes: [NSAttributedString.Key: Any], in rect: NSRect) {
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attributes)
        let point = NSPoint(
            x: rect.maxX - size.width,
            y: rect.minY + max(0, (rect.height - size.height) / 2)
        )
        label.draw(at: point, withAttributes: attributes)
    }

    private func lineCount(in string: String) -> Int {
        if string.isEmpty { return 1 }
        var count = 0
        (string as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: (string as NSString).length),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        if string.hasSuffix("\n") { count += 1 }
        return max(1, count)
    }
}
