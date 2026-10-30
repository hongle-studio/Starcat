//
//  ScreensaverGridView.swift
//  StarcatScreensaver
//
//  与 App Ambient 相同的无缝五行网格，格子只显示图片。
//

import SwiftUI

struct ScreensaverGridView: View {
    let snapshots: [AmbientSlotSnapshot]
    let metrics: AmbientGridMetrics
    let changedSlotIDs: Set<Int>
    let flipDuration: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 0) {
            ForEach(snapshots) { snapshot in
                ScreensaverCellView(
                    snapshot: snapshot,
                    tilePointSize: metrics.tilePointSize,
                    flipDuration: flipDuration,
                    animatesCardChange: !reduceMotion && changedSlotIDs.contains(snapshot.id)
                )
            }
        }
        .frame(width: metrics.contentWidth, height: metrics.contentHeight)
        .frame(width: metrics.viewportWidth, height: metrics.viewportHeight)
        .clipped()
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(metrics.tilePointSize),
                spacing: 0,
                alignment: .center
            ),
            count: metrics.columnCount
        )
    }
}
