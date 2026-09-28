//
//  ScreensaverCellView.swift
//  StarcatScreensaver
//
//  单格 Y 轴翻转。故意不渲染 title / 渐变遮罩，只保留 artwork。
//

import SwiftUI

struct ScreensaverCellView: View {
    let snapshot: AmbientSlotSnapshot
    let tilePointSize: Double
    let flipDuration: TimeInterval
    let animatesCardChange: Bool

    @State private var displayedCard: AmbientCardModel?
    @State private var rotationDegrees = 0.0
    @State private var transitionGeneration: UInt64 = 0

    init(
        snapshot: AmbientSlotSnapshot,
        tilePointSize: Double,
        flipDuration: TimeInterval,
        animatesCardChange: Bool
    ) {
        self.snapshot = snapshot
        self.tilePointSize = tilePointSize
        self.flipDuration = flipDuration
        self.animatesCardChange = animatesCardChange
        _displayedCard = State(initialValue: snapshot.card)
    }

    var body: some View {
        ZStack {
            if let displayedCard {
                ScreensaverArtworkView(card: displayedCard, tilePointSize: tilePointSize)
            } else {
                Color.black
            }
        }
        .frame(width: tilePointSize, height: tilePointSize)
        .clipped()
        .rotation3DEffect(
            .degrees(rotationDegrees),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.7
        )
        .onChange(of: snapshot.card) { _, newCard in
            updateDisplayedCard(to: newCard)
        }
    }

    private func updateDisplayedCard(to newCard: AmbientCardModel?) {
        guard displayedCard != newCard else { return }
        transitionGeneration &+= 1
        let requestedGeneration = transitionGeneration
        guard animatesCardChange,
              displayedCard != nil,
              newCard != nil,
              flipDuration > 0 else {
            replaceWithoutAnimation(with: newCard)
            return
        }

        let halfDuration = flipDuration / 2
        withAnimation(.easeIn(duration: halfDuration)) {
            rotationDegrees = 90
        } completion: {
            guard transitionGeneration == requestedGeneration else { return }
            replaceWithoutAnimation(with: newCard, rotationDegrees: -90)
            withAnimation(.easeOut(duration: halfDuration)) {
                rotationDegrees = 0
            }
        }
    }

    private func replaceWithoutAnimation(
        with card: AmbientCardModel?,
        rotationDegrees: Double = 0
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedCard = card
            self.rotationDegrees = rotationDegrees
        }
    }
}
