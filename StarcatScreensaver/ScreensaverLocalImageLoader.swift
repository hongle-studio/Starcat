//
//  ScreensaverLocalImageLoader.swift
//  StarcatScreensaver
//
//  屏保格子会频繁重绘（翻格、Observation）。每次 `NSImage(contentsOf:)` 打磁盘
//  会把空闲屏保拖成 IO。按 path + mtime 缓存，文件被原子替换后自动失效。
//

import AppKit
import Foundation

/// 本地头像解码缓存。屏保进程禁止走 Kingfisher。
enum ScreensaverLocalImageLoader {
    /// NSCache 本身线程安全，Swift 6 仍不把它标成 Sendable，所以用盒子收口。
    private static let images = ImageCache()

    static func image(at url: URL) -> NSImage? {
        guard url.isFileURL else { return nil }
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)#\(modifiedAt)" as NSString
        if let cached = images.storage.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images.storage.setObject(image, forKey: key)
        return image
    }
}

private final class ImageCache: @unchecked Sendable {
    let storage = NSCache<NSString, NSImage>()

    init() {
        storage.countLimit = 128
    }
}
