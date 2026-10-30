//
//  LocalAILogTextView.swift
//  Starcat
//
//  日志正文的窄 AppKit 桥接：原生跨行选中/复制，增量追加，用户阅读时不抢滚动位置。
//  窗口/筛选/暂停状态仍由 SwiftUI 持有，Coordinator 只维护文本渲染差量。
//

import AppKit
import SwiftUI

struct LocalAILogTextView: NSViewRepresentable {
    let rows: [LocalAILogEvent]
    let fontSize: CGFloat
    @Binding var followsTail: Bool

    func makeCoordinator() -> Coordinator { Coordinator(followsTail: $followsTail) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView()
        context.coordinator.connect(scroll)
        return scroll
    }

    /// 独立工厂便于在不创建窗口、不操作桌面的单测中验证原生文本行为。
    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isAutomaticLinkDetectionEnabled = false
        text.allowsUndo = false
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = text.maxSize
        text.textContainer?.widthTracksTextView = false
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        scroll.documentView = text
        text.setAccessibilityLabel(String.l10n("localai.logs.contents"))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.followsTail = $followsTail
        scroll.documentView?.setAccessibilityLabel(String.l10n("localai.logs.contents"))
        context.coordinator.update(rows: rows, in: scroll, fontSize: fontSize)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.disconnect() }

    /// NSTextStorage 持有展示文本，行 ID/UTF16 长度只用于 append/trim，避免每帧替换全文。
    @MainActor final class Coordinator: NSObject {
        var followsTail: Binding<Bool>
        private var ids: [UUID] = []
        private var lengths: [Int] = []
        private var lastFollow = true
        private var fontSize: CGFloat = 0
        private weak var scrollView: NSScrollView?

        init(followsTail: Binding<Bool>) { self.followsTail = followsTail }

        func connect(_ scroll: NSScrollView) {
            scrollView = scroll
            NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                name: NSScrollView.didLiveScrollNotification, object: scroll)
        }

        func disconnect() { NotificationCenter.default.removeObserver(self) }

        @objc private func didScroll() {
            guard let scroll = scrollView, let text = scroll.documentView else { return }
            let atBottom = scroll.contentView.bounds.maxY >= text.bounds.maxY - 8
            if !atBottom, followsTail.wrappedValue { followsTail.wrappedValue = false }
        }

        func update(rows: [LocalAILogEvent], in scroll: NSScrollView, fontSize: CGFloat) {
            guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
            let nextIDs = rows.map(\.id)
            let didChange = ids != nextIDs
            let oldOrigin = scroll.contentView.bounds.origin
            let oldSelection = text.selectedRange()
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let changedFont = self.fontSize != fontSize
            self.fontSize = fontSize
            if changedFont { text.font = font }
            if didChange {
                let trim = nextIDs.first.flatMap { ids.firstIndex(of: $0) } ?? ids.count
                let retained = Array(ids.dropFirst(trim))
                let canAppend = Array(nextIDs.prefix(retained.count)) == retained
                let removed = canAppend ? lengths.prefix(trim).reduce(0, +) : storage.length
                storage.beginEditing()
                if canAppend {
                    storage.deleteCharacters(in: NSRange(location: 0, length: removed))
                    lengths.removeFirst(trim)
                    for row in rows.dropFirst(retained.count) { append(row, to: storage, font: font) }
                } else {
                    storage.setAttributedString(NSAttributedString())
                    lengths.removeAll()
                    for row in rows { append(row, to: storage, font: font) }
                }
                storage.endEditing()
                ids = nextIDs
                if !followsTail.wrappedValue {
                    let start = min(max(0, oldSelection.location - removed), storage.length)
                    let end = min(max(start, NSMaxRange(oldSelection) - removed), storage.length)
                    text.setSelectedRange(NSRange(location: start, length: end - start))
                    let lineHeight = text.layoutManager?.defaultLineHeight(for: font) ?? fontSize * 1.4
                    scroll.contentView.scroll(to: NSPoint(x: oldOrigin.x, y: max(0, oldOrigin.y - CGFloat(trim) * lineHeight)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            if changedFont, storage.length > 0 {
                storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            }
            if followsTail.wrappedValue, didChange || !lastFollow {
                text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
            }
            lastFollow = followsTail.wrappedValue
        }

        private func append(_ event: LocalAILogEvent, to storage: NSTextStorage, font: NSFont) {
            let line = event.line + "\n"
            lengths.append(line.utf16.count)
            storage.append(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
    }
}
