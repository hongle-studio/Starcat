//
//  ScreensaverArtworkView.swift
//  StarcatScreensaver
//
//  从 App Group 本地文件加载头像。屏保进程禁止走 Kingfisher / GitHub。
//

import AppKit
import SwiftUI

struct ScreensaverArtworkView: View {
    let card: AmbientCardModel
    let tilePointSize: Double

    var body: some View {
        ZStack {
            ScreensaverArtworkPlaceholder(card: card)

            if let image = localImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: tilePointSize, height: tilePointSize)
        .clipped()
        .accessibilityHidden(true)
    }

    private var localImage: NSImage? {
        guard let artworkURLString = card.artworkURLString,
              let url = URL(string: artworkURLString),
              url.isFileURL else {
            return nil
        }
        return ScreensaverLocalImageLoader.image(at: url)
    }
}

private struct ScreensaverArtworkPlaceholder: View {
    let card: AmbientCardModel

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.29, blue: 0.35),
        Color(red: 0.30, green: 0.23, blue: 0.36),
        Color(red: 0.20, green: 0.34, blue: 0.31),
        Color(red: 0.37, green: 0.25, blue: 0.23),
        Color(red: 0.25, green: 0.29, blue: 0.43),
        Color(red: 0.35, green: 0.31, blue: 0.20),
        Color(red: 0.25, green: 0.35, blue: 0.40),
        Color(red: 0.39, green: 0.24, blue: 0.31)
    ]

    var body: some View {
        ZStack {
            Self.palette[AmbientArtworkStyle.paletteIndex(for: card.id)]

            if let monogram = AmbientArtworkStyle.monogram(from: card.title) {
                Text(monogram)
                    .font(.largeTitle)
                    .bold()
                    .foregroundStyle(.primary)
            }
        }
    }
}
