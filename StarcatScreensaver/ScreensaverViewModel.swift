//
//  ScreensaverViewModel.swift
//  StarcatScreensaver
//
//  屏保进程内的 Engine 调度。只读本地快照，不预取网络图片、不写 AppLog。
//  空快照保持 empty，由根视图画应用图标。
//

import Foundation
import Observation

enum ScreensaverLoadState: Equatable, Sendable {
    case idle
    case loading
    case empty
    case loaded([AmbientSlotSnapshot])
}

@MainActor
@Observable
final class ScreensaverViewModel {
    private(set) var state: ScreensaverLoadState = .idle
    private(set) var changedSlotIDs: Set<Int> = []
    private(set) var isSchedulerRunning = false

    @ObservationIgnored private let catalog: any AmbientCatalogProviding
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let sleep: (TimeInterval) async throws -> Void
    @ObservationIgnored private let randomSeed: () -> UInt64

    @ObservationIgnored private var engine: AmbientGridEngine?
    @ObservationIgnored private var currentLayout: AmbientGridLayout?
    @ObservationIgnored private var currentReduceMotion = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshotRevision: ScreensaverSnapshotRevision?
    @ObservationIgnored private var lastArtworkSignature: Int?

    init(
        catalog: (any AmbientCatalogProviding)? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        randomSeed: @escaping () -> UInt64 = {
            UInt64.random(in: UInt64.min...UInt64.max)
        }
    ) {
        if let catalog {
            self.catalog = catalog
        } else {
            self.catalog = ScreensaverViewModel.makeProductionCatalog()
        }
        self.now = now
        self.sleep = sleep
        self.randomSeed = randomSeed
    }

    func configure(layout: AmbientGridLayout, reduceMotion: Bool) {
        let isSameLayout = currentLayout == layout
        currentReduceMotion = reduceMotion
        if isSameLayout, case .loaded = state {
            restartSchedulerForCurrentPolicy()
            startSnapshotRefreshLoop()
            return
        }

        generation &+= 1
        let requestedGeneration = generation
        currentLayout = layout
        state = .loading
        changedSlotIDs = []
        engine = nil
        lastSnapshotRevision = nil
        lastArtworkSignature = nil
        loadTask?.cancel()
        stopScheduler()
        startSnapshotRefreshLoop()

        loadTask = Task { [weak self, catalog] in
            do {
                let cards = try await catalog.loadCards(scene: .owners)
                try Task.checkCancellation()
                guard let self, self.generation == requestedGeneration,
                      self.currentLayout == layout else { return }
                self.install(cards: cards, layout: layout)
            } catch {
                guard let self, self.generation == requestedGeneration else { return }
                self.state = .empty
                self.engine = nil
                self.stopScheduler()
            }
        }
    }

    func updateReduceMotion(_ reduceMotion: Bool) {
        guard currentReduceMotion != reduceMotion else { return }
        currentReduceMotion = reduceMotion
        restartSchedulerForCurrentPolicy()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            advanceAndPublish(at: now())
            restartSchedulerForCurrentPolicy()
            startSnapshotRefreshLoop()
        } else {
            stopScheduler()
        }
    }

    private func install(cards: [AmbientCardModel], layout: AmbientGridLayout) {
        guard !cards.isEmpty, layout.config.slotCount > 0 else {
            state = .empty
            engine = nil
            stopScheduler()
            return
        }

        let engine = AmbientGridEngine(
            cards: cards,
            config: layout.config,
            now: now(),
            randomSeed: randomSeed()
        )
        self.engine = engine
        changedSlotIDs = []
        lastArtworkSignature = ScreensaverArtworkSignature.make(cards)
        lastSnapshotRevision = snapshotRevision()
        state = .loaded(engine.snapshots)
        restartSchedulerForCurrentPolicy()
    }

    /// 头像后台落盘时需要补进格子，但不能每两秒解码 JSON、重绘整墙。
    /// 闲置路径只 stat 快照文件；mtime/size 变了才 load，图片集合没变就不写 `state`。
    private func startSnapshotRefreshLoop() {
        guard snapshotRefreshTask == nil else { return }
        snapshotRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.sleep(2)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refreshCardsFromCatalog()
            }
        }
    }

    private func refreshCardsFromCatalog() async {
        guard let layout = currentLayout else { return }
        let revision = snapshotRevision()
        if let revision, revision == lastSnapshotRevision {
            return
        }
        do {
            let cards = try await catalog.loadCards(scene: .owners)
            try Task.checkCancellation()
            lastSnapshotRevision = revision
            guard !cards.isEmpty else { return }
            let signature = ScreensaverArtworkSignature.make(cards)
            if signature == lastArtworkSignature {
                return
            }
            lastArtworkSignature = signature
            if var engine {
                let before = engine.snapshots
                engine.refreshCards(cards)
                self.engine = engine
                if engine.snapshots != before {
                    state = .loaded(engine.snapshots)
                }
            } else {
                install(cards: cards, layout: layout)
            }
        } catch {
            lastSnapshotRevision = revision
            return
        }
    }

    private func snapshotRevision() -> ScreensaverSnapshotRevision? {
        (catalog as? ScreensaverSnapshotCatalog)?.store.revision()
    }

    private func restartSchedulerForCurrentPolicy() {
        stopScheduler()
        guard !currentReduceMotion, isActive, engine?.nextDeadline != nil else { return }

        isSchedulerRunning = true
        schedulerTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self, let deadline = self.engine?.nextDeadline else { return }
                    let delay = max(0, deadline - self.now())
                    try await self.sleep(delay)
                    try Task.checkCancellation()
                    self.advanceAndPublish(at: self.now())
                }
            } catch {
                return
            }
        }
    }

    private func stopScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
        isSchedulerRunning = false
    }

    private func advanceAndPublish(at uptime: TimeInterval) {
        guard var engine else { return }
        let result = engine.advance(now: uptime)
        self.engine = engine
        changedSlotIDs = result.changedSlotIDs
        state = .loaded(result.snapshots)
    }

    private static func makeProductionCatalog() -> any AmbientCatalogProviding {
        ScreensaverSnapshotCatalog(
            store: ScreensaverSnapshotStore(
                containerURL: ScreensaverSharedConfiguration.productionContainerURL()
            )
        )
    }
}
