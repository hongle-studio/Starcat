//
//  ReadmeStarHistoryPreviewTests.swift
//  StarcatTests
//
//  验证 README 末尾 Star History 的 cache-first、隐私门禁、全历史范围和安全渲染。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("README Star History")
struct ReadmeStarHistoryPreviewTests {
    @Test("首次进入 README 后先显示 SQLite 缓存，再等待后台刷新")
    func cachedHistoryAppearsBeforeRefreshCompletes() async {
        let gate = ReadmeStarHistoryLoadGate()
        let cached = Self.snapshot(state: .cached)
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: cached,
            refreshSnapshot: cached,
            refreshGate: gate
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                repo: Self.repo(),
                databaseScopeRevision: 1,
                locale: Locale(identifier: "en")
            )
        }
        await gate.waitUntilBlocked()

        #expect(viewModel.renderState.html?.contains("starcat-star-history-line") == true)
        #expect(await repository.cachedRanges() == [.all])
        #expect(await repository.refreshRanges() == [.all])

        await gate.release()
        await load.value
    }

    @Test("无缓存时先显示骨架，官方历史返回后原地替换")
    func loadingSkeletonIsReplacedByOfficialHistory() async {
        let gate = ReadmeStarHistoryLoadGate()
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(points: [], state: .cached),
            refreshSnapshot: Self.snapshot(state: .fresh),
            refreshGate: gate
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                repo: Self.repo(),
                databaseScopeRevision: 1,
                locale: Locale(identifier: "en")
            )
        }
        await gate.waitUntilBlocked()

        #expect(viewModel.renderState.html?.contains("starcat-star-history-skeleton") == true)
        #expect(viewModel.renderState.html?.contains(#"aria-busy="true""#) == true)
        // 骨架本身不算入场帧；官方历史替换骨架才是曲线首次出现的那一帧。
        #expect(viewModel.renderState.prefersAnimatedEntrance == false)

        await gate.release()
        await load.value

        #expect(viewModel.renderState.html?.contains("starcat-star-history-line") == true)
        #expect(viewModel.renderState.html?.contains("starcat-star-history-skeleton") == false)
        #expect(viewModel.renderState.prefersAnimatedEntrance == true)
    }

    @Test("入场生长动画只在首张正式卡片标记，网络刷新重渲染不重播")
    func entranceAnimationMarksOnlyFirstCard() async {
        let gate = ReadmeStarHistoryLoadGate()
        let refreshed = Self.snapshot(points: [
            StarHistoryPoint(date: StarHistoryDateCodec.date(from: "2020-02-01")!, count: 10),
            StarHistoryPoint(date: StarHistoryDateCodec.date(from: "2026-09-05")!, count: 300)
        ], state: .fresh)
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(state: .cached),
            refreshSnapshot: refreshed,
            refreshGate: gate
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                repo: Self.repo(),
                databaseScopeRevision: 1,
                locale: Locale(identifier: "en")
            )
        }
        await gate.waitUntilBlocked()

        // 缓存命中的首张正式卡片是入场帧，值得播曲线生长动画。
        #expect(viewModel.renderState.prefersAnimatedEntrance == true)

        await gate.release()
        await load.value

        // 网络刷新带回新数据属于原地更新，曲线不能整条重画一遍。
        #expect(viewModel.renderState.prefersAnimatedEntrance == false)
    }

    @Test("无缓存且远端无可用历史时移除骨架")
    func terminalEmptyHistoryRemovesLoadingSkeleton() async {
        let empty = Self.snapshot(points: [], state: .unavailable)
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: empty,
            refreshSnapshot: empty
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )

        await viewModel.loadIfNeeded(
            repo: Self.repo(),
            databaseScopeRevision: 1,
            locale: Locale(identifier: "en")
        )

        #expect(viewModel.renderState.html == nil)
    }

    @Test("首帧预加载与底部兜底共享同一次加载")
    func repeatedLoadForSameIdentityDoesNotDuplicateRequests() async {
        let gate = ReadmeStarHistoryLoadGate()
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(points: [], state: .cached),
            refreshSnapshot: Self.snapshot(state: .fresh),
            refreshGate: gate
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )
        let repo = Self.repo()
        let locale = Locale(identifier: "en")

        let preload = Task {
            await viewModel.loadIfNeeded(repo: repo, databaseScopeRevision: 1, locale: locale)
        }
        await gate.waitUntilBlocked()
        await viewModel.loadIfNeeded(repo: repo, databaseScopeRevision: 1, locale: locale)
        await gate.release()
        await preload.value
        await viewModel.loadIfNeeded(repo: repo, databaseScopeRevision: 1, locale: locale)

        #expect(await repository.cachedRanges() == [.all])
        #expect(await repository.refreshRanges() == [.all])
    }

    @Test("零 Star 仓库不读取缓存、不请求远端且不展示卡片")
    func zeroStarRepositorySkipsHistoryEntirely() async {
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(state: .cached),
            refreshSnapshot: Self.snapshot(state: .fresh)
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )
        var repo = Self.repo()
        repo.starsCount = 0

        await viewModel.loadIfNeeded(
            repo: repo,
            databaseScopeRevision: 1,
            locale: Locale(identifier: "en")
        )

        #expect(viewModel.renderState.html == nil)
        #expect(await repository.cachedRanges().isEmpty)
        #expect(await repository.refreshRanges().isEmpty)
    }

    @Test("Internal 仓库不读取历史缓存也不请求远端")
    func internalRepositorySkipsHistory() async {
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(state: .cached),
            refreshSnapshot: Self.snapshot(state: .fresh)
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .internal }
        )

        await viewModel.loadIfNeeded(
            repo: Self.repo(),
            databaseScopeRevision: 1,
            locale: Locale(identifier: "en")
        )

        #expect(viewModel.renderState.html == nil)
        #expect(await repository.cachedRanges().isEmpty)
        #expect(await repository.refreshRanges().isEmpty)
    }

    @Test("取消后迟到的刷新结果不能重新写入 README")
    func cancelledLoadCannotRestoreOldRepositoryHTML() async {
        let gate = ReadmeStarHistoryLoadGate()
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(points: [], state: .cached),
            refreshSnapshot: Self.snapshot(state: .fresh),
            refreshGate: gate
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                repo: Self.repo(),
                databaseScopeRevision: 1,
                locale: Locale(identifier: "en")
            )
        }
        await gate.waitUntilBlocked()
        viewModel.cancel()
        await gate.release()
        await load.value

        #expect(viewModel.renderState == .empty)
    }

    @Test("取消异步任务后迟到的刷新结果不能写入 README")
    func cancelledTaskCannotApplyDelayedRefresh() async {
        let gate = ReadmeStarHistoryLoadGate()
        let repository = ReadmeStarHistoryRepositoryStub(
            cachedSnapshot: Self.snapshot(points: [], state: .cached),
            refreshSnapshot: Self.snapshot(state: .fresh),
            refreshGate: gate
        )
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { _ in .public }
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                repo: Self.repo(),
                databaseScopeRevision: 1,
                locale: Locale(identifier: "en")
            )
        }
        await gate.waitUntilBlocked()
        load.cancel()
        await gate.release()
        await load.value

        #expect(viewModel.renderState.html == nil)
    }

    @Test("README 只展示至少两个 GitHub 官方历史点")
    func visibilityRequiresPublicOfficialHistoryPoints() {
        let repo = Self.repo()

        #expect(ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: repo,
            projectVisibility: nil,
            snapshot: Self.snapshot(state: .cached)
        ))
        #expect(!ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: repo,
            projectVisibility: nil,
            snapshot: Self.snapshot(
                points: Self.points(source: .ghArchive, precision: .estimated),
                state: .cached
            )
        ))
        #expect(!ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: repo,
            projectVisibility: .private,
            snapshot: Self.snapshot(state: .cached)
        ))
        var zeroStarRepo = repo
        zeroStarRepo.starsCount = 0
        #expect(!ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: zeroStarRepo,
            projectVisibility: .public,
            snapshot: Self.snapshot(state: .cached)
        ))
    }

    @Test("HTML 转义不能让动态文本注入标签或属性")
    func htmlEscapingCoversTextAndAttributes() {
        let escaped = ReadmeStarHistoryHTMLRenderer.escape("<img src=x onerror='bad'>&\"")

        #expect(escaped == "&lt;img src=x onerror=&#39;bad&#39;&gt;&amp;&quot;")
        #expect(!escaped.contains("<img"))
    }

    @Test("SVG 刻度必须输出 HTML，不能泄漏 GRDB SQL 插值调试描述")
    func renderedHTMLUsesStringFragmentsForAxisTicks() throws {
        let snapshot = Self.snapshot(state: .cached)
        let model = StarHistoryChartRenderModel(
            points: snapshot.points,
            range: .all,
            repositoryCreatedAt: StarHistoryDateCodec.date(from: "2020-01-01")
        )
        let html = try #require(ReadmeStarHistoryHTMLRenderer.render(
            snapshot: snapshot,
            model: model,
            repo: Self.repo(),
            locale: Locale(identifier: "zh-Hans"),
            context: ReadmeStarHistoryHTMLRenderer.ReadmeStarHistoryRenderContext.prepare(language: Self.repo().language)
        ))

        #expect(!html.contains("GRDB.SQL"))
        #expect(html.contains("starcat-star-history-grid-horizontal"))
        #expect(html.contains("starcat-star-history-axis-y"))
    }

    @Test("图表包含参考样式所需的标题、坐标、面积和末端点")
    func renderedHTMLContainsCompleteChartStructure() throws {
        let points = [
            StarHistoryPoint(
                date: StarHistoryDateCodec.date(from: "2026-07-23")!,
                count: 0,
                source: .githubHistory,
                precision: .reconstructed,
                fetchedAt: StarHistoryDateCodec.date(from: "2026-09-06")
            ),
            StarHistoryPoint(
                date: StarHistoryDateCodec.date(from: "2026-09-06")!,
                count: 1_165,
                source: .githubHistory,
                precision: .reconstructed,
                fetchedAt: StarHistoryDateCodec.date(from: "2026-09-06")
            )
        ]
        let snapshot = Self.snapshot(points: points, state: .cached)
        let model = StarHistoryChartRenderModel(
            points: snapshot.points,
            range: .all,
            repositoryCreatedAt: StarHistoryDateCodec.date(from: "2026-07-23"),
            now: StarHistoryDateCodec.date(from: "2026-09-06")!
        )
        let html = try #require(ReadmeStarHistoryHTMLRenderer.render(
            snapshot: snapshot,
            model: model,
            repo: Self.repo(),
            locale: Locale(identifier: "en"),
            avatarDataURI: "data:image/png;base64,Y2FjaGVk",
            context: ReadmeStarHistoryHTMLRenderer.ReadmeStarHistoryRenderContext.prepare(language: Self.repo().language)
        ))

        #expect(html.contains(#"class="starcat-star-history-card""#))
        #expect(html.contains("GitHub Star History"))
        #expect(html.contains("Powered by"))
        #expect(html.contains("<strong>Starcat</strong>"))
        #expect(html.contains("octo/history"))
        #expect(html.contains(#"class="starcat-star-history-avatar""#))
        #expect(html.contains(#"src="data:image/png;base64,Y2FjaGVk""#))
        #expect(!html.contains("https://github.com/octo.png"))
        #expect(html.contains(#"class="starcat-star-history-card-kicker""#))
        #expect(html.contains(#"class="starcat-star-history-current-star""#))
        #expect(html.contains(#"class="starcat-star-history-area""#))
        #expect(html.contains("starcat-star-history-metrics"))
        #expect(html.contains("starcat-star-history-callouts"))
        #expect(html.contains("starcat-star-history-gradient-top"))
        #expect(html.contains(">1.2K</text>"))
        #expect(!html.contains(">1,165</text>"))
        #expect(html.components(separatedBy: "starcat-star-history-axis-y").count - 1 == 5)
    }

    // MARK: - 身份键 / 悬停序列 / 渲染指纹

    @Test("身份键与 id 同义：同日同源相等，同日不同源不等")
    func pointKeyMatchesIdentifierEquivalence() throws {
        let day = try #require(StarHistoryDateCodec.date(from: "2026-09-05"))
        let morning = StarHistoryPoint(date: day, count: 10, source: .githubHistory)
        // 同一天的不同时刻必须落在同一个键上：日序号按 UTC 日边界取整。
        let afternoon = StarHistoryPoint(date: day.addingTimeInterval(12 * 3_600), count: 10, source: .githubHistory)
        let nextDay = StarHistoryPoint(date: day.addingTimeInterval(86_400), count: 10, source: .githubHistory)
        // 来源交接处同一天会同时存在两个点，键必须区分它们。
        let legacy = StarHistoryPoint(date: day, count: 10, source: .ghArchive)

        #expect(morning.key == afternoon.key)
        #expect(morning.dayOrdinal == afternoon.dayOrdinal)
        #expect(morning.id == afternoon.id)
        #expect(morning.key != nextDay.key)
        #expect(morning.key != legacy.key)
        #expect(morning.id != legacy.id)
    }

    @Test("长历史把悬停序列抽稀到 400 点以内，且标注索引落在同一份数组里")
    func longHistoryHoverSeriesIsBoundedAndConsistent() async throws {
        let start = try #require(StarHistoryDateCodec.date(from: "2015-01-01"))
        let end = try #require(StarHistoryDateCodec.date(from: "2026-09-06"))
        // 约 4270 天 ≈ 610 周，golang/go 量级：改动前这里会整份塞进 data-points。
        let days = Int(end.timeIntervalSince(start) / 86_400)
        let points = (0...days).map { index in
            StarHistoryPoint(date: start.addingTimeInterval(Double(index) * 86_400), count: index * 3)
        }
        var repo = Self.repo()
        repo.starsCount = try #require(points.last).count
        let snapshot = StarHistorySnapshot(range: .all, points: points, remoteState: .fresh,
                                           coverageStart: start, updatedAt: end)
        let model = StarHistoryChartRenderModel(points: points, range: .all, repositoryCreatedAt: start)
        let html = try #require(ReadmeStarHistoryHTMLRenderer.render(
            snapshot: snapshot, model: model, repo: repo,
            locale: Locale(identifier: "en"), now: end,
            context: ReadmeStarHistoryHTMLRenderer.ReadmeStarHistoryRenderContext.prepare(language: repo.language)
        ))

        let hover = try Self.series(html, attribute: "data-points")
        let drawn = try Self.series(html, attribute: "data-rendered")
        #expect(hover.count <= ReadmeStarHistoryHTMLRenderer.hoverPointLimit)
        // 不能退化成折线那套 ≤90 点：悬停要能停在具体某一天。
        #expect(hover.count > 90)
        #expect(drawn.count <= 90)
        #expect(hover.first?[1] == Double(try #require(points.first).count))
        #expect(hover.last?[1] == Double(try #require(points.last).count))

        // data-annotations 的 index 是 data-points 的下标；不同源就会标到别的日子上。
        let annotations = try Self.annotations(html)
        #expect(!annotations.isEmpty)
        for annotation in annotations {
            let index = try #require(annotation["index"] as? Int)
            #expect(index >= 0)
            #expect(index < hover.count)
        }
        let current = try #require(annotations.first { $0["kind"] as? String == "current" })
        #expect(current["index"] as? Int == hover.count - 1)
    }

    @Test("渲染指纹对每个会影响卡片的输入都敏感")
    func renderFingerprintTracksEveryRenderedInput() async throws {
        let snapshot = Self.snapshot(state: .fresh)
        let other = Self.snapshot(points: [
            StarHistoryPoint(date: StarHistoryDateCodec.date(from: "2020-02-01")!, count: 11),
            StarHistoryPoint(date: StarHistoryDateCodec.date(from: "2026-09-05")!, count: 201)
        ], state: .fresh)
        // 同一个模型实例复用两次构造：避免 now 依赖带来的比较抖动（xDomain 可能取 now）。
        let defaultModel = StarHistoryChartRenderModel(points: snapshot.points, range: .all, repositoryCreatedAt: nil)
        let repo = Self.repo()

        func fingerprint(
            snapshot: StarHistorySnapshot = snapshot,
            repo: Repo = repo,
            model: StarHistoryChartRenderModel? = nil,
            avatar: String? = nil,
            locale: String = "en",
            nowDay: Int = 20_000
        ) -> ReadmeStarHistoryViewModel.RenderFingerprint {
            ReadmeStarHistoryViewModel.RenderFingerprint(
                snapshot: snapshot,
                repo: repo,
                model: model ?? defaultModel,
                avatarDataURI: avatar,
                localeIdentifier: locale,
                nowDay: nowDay
            )
        }

        #expect(fingerprint() == fingerprint())
        // 描述 / Topics / 星标数：手写字段清单最容易漏掉这几项，整值比较不会。
        var described = repo
        described.description = "changed"
        #expect(fingerprint() != fingerprint(repo: described))
        var starred = repo
        starred.starsCount += 1
        #expect(fingerprint() != fingerprint(repo: starred))
        var topicsChanged = repo
        topicsChanged.topics = #"[\"a\",\"b\"]"#
        #expect(fingerprint() != fingerprint(repo: topicsChanged))
        // 头像晚到、语言切换、跨天（年龄/窗口天数变化）。
        #expect(fingerprint() != fingerprint(avatar: "data:image/png;base64,YQ=="))
        #expect(fingerprint() != fingerprint(locale: "zh-Hans"))
        #expect(fingerprint() != fingerprint(nowDay: 20_001))
        // 历史数据本身。
        #expect(fingerprint() != fingerprint(snapshot: other))
        // 绘制序列（模型）也算输入：它决定折线。
        #expect(fingerprint() != fingerprint(model: StarHistoryChartRenderModel(points: snapshot.points, range: .threeMonths, repositoryCreatedAt: nil)))
    }

    @Test("切到不可见仓库再切回来，卡片必须重新生成")
    func cardReappearsAfterSwitchingAway() async {
        let snapshot = Self.snapshot(state: .cached)
        let repository = ReadmeStarHistoryRepositoryStub(cachedSnapshot: snapshot, refreshSnapshot: snapshot)
        let visibleRepoID: Int64 = 42
        let viewModel = ReadmeStarHistoryViewModel(
            repository: repository,
            projectVisibilityProvider: { repoID in repoID == visibleRepoID ? .public : .private }
        )
        let visible = Self.repo()
        var hidden = Repo.makeMinimal(owner: "octo", name: "hidden")
        hidden.id = 99
        hidden.starsCount = 200

        await viewModel.loadIfNeeded(repo: visible, databaseScopeRevision: 1, locale: Locale(identifier: "en"))
        #expect(viewModel.renderState.html != nil)

        // 私有仓库不展示并清空 DOM；此时指纹若没跟着失效，
        // 切回可见仓库时会因为"输入没变"而短路，卡片就再也不出现。
        await viewModel.loadIfNeeded(repo: hidden, databaseScopeRevision: 1, locale: Locale(identifier: "en"))
        #expect(viewModel.renderState.html == nil)

        await viewModel.loadIfNeeded(repo: visible, databaseScopeRevision: 1, locale: Locale(identifier: "en"))
        #expect(viewModel.renderState.html != nil)
    }

    private nonisolated static func repo() -> Repo {
        var repo = Repo.makeMinimal(owner: "octo", name: "history")
        repo.id = 42
        repo.starsCount = 200
        repo.createdAt = "2020-01-01T00:00:00Z"
        repo.cachedAt = "2026-09-06T00:00:00Z"
        return repo
    }

    @Test("整刻度上限覆盖峰值，避免按峰值五等分产生零碎数值", arguments: [0, 1, 9, 99, 1_165, 50_511, 100_001, 999_999, 4_000_000])
    func niceAxisCoversPeak(peak: Int) {
        let axis = ReadmeStarHistoryAxis(peak: peak)
        #expect(axis.maximum >= Double(peak))
        #expect(axis.step >= 1)
        #expect(axis.ticks.count == 5)
        #expect(axis.ticks.first == 0)
        #expect(axis.ticks.last == axis.maximum)
        #expect(Set(axis.ticks).count == 5)
        if peak == 50_511 {
            #expect(axis.ticks == [0, 15_000, 30_000, 45_000, 60_000])
        }
    }

    @Test("90 天统计使用完整日序列，按期初数计算增长率")
    func ninetyDayGrowthUsesBaseline() throws {
        let end = try #require(StarHistoryDateCodec.date(from: "2026-09-06"))
        let points = [
            StarHistoryPoint(date: end.addingTimeInterval(-100 * 86_400), count: 20_000),
            StarHistoryPoint(date: end.addingTimeInterval(-90 * 86_400), count: 38_155),
            StarHistoryPoint(date: end.addingTimeInterval(-89 * 86_400), count: 40_000),
            StarHistoryPoint(date: end, count: 50_495)
        ]
        let metrics = ReadmeStarHistoryMetrics(snapshot: Self.snapshot(points: points, state: .fresh), createdAt: nil)
        #expect(metrics.growth == 12_340)
        #expect(metrics.periodDays == 90)
        #expect(abs(try #require(metrics.dailyAverage) - 12_340.0 / 90) < 0.000001)
        #expect(abs(try #require(metrics.growthRate) - 12_340.0 / 38_155) < 0.000001)
        #expect(!metrics.isEstimated)
        #expect(!metrics.sinceCreated)
    }

    @Test("历史不足不能补造零基线，新仓零基线不能显示无穷增长率")
    func incompleteCoverageAndNewRepositoryAreDistinct() throws {
        let end = try #require(StarHistoryDateCodec.date(from: "2026-09-06"))
        let points = [StarHistoryPoint(date: end.addingTimeInterval(-20 * 86_400), count: 10), StarHistoryPoint(date: end, count: 200)]
        let snapshot = Self.snapshot(points: points, state: .cached)
        let old = ReadmeStarHistoryMetrics(snapshot: snapshot, createdAt: end.addingTimeInterval(-200 * 86_400))
        #expect(old.growth == nil)
        #expect(old.growthRate == nil)
        #expect(old.dailyAverage == nil)
        let young = ReadmeStarHistoryMetrics(snapshot: snapshot, createdAt: end.addingTimeInterval(-25 * 86_400), now: end)
        #expect(young.growth == 200)
        #expect(young.growthRate == nil)
        #expect(young.sinceCreated)
        #expect(young.ageDays == 25)
        #expect(young.dailyAverage == 8)
    }

    @Test("日均新增保留负值，不足一天不能强行补成一天")
    func dailyAverageHandlesDeclineAndSameDayCreation() throws {
        let end = try #require(StarHistoryDateCodec.date(from: "2026-09-06"))
        let points = [StarHistoryPoint(date: end.addingTimeInterval(-90 * 86_400), count: 300),
                      StarHistoryPoint(date: end, count: 210)]
        let decline = ReadmeStarHistoryMetrics(snapshot: Self.snapshot(points: points, state: .fresh), createdAt: nil)
        #expect(decline.dailyAverage == -1)
        let sameDay = ReadmeStarHistoryMetrics(snapshot: Self.snapshot(points: points, state: .fresh),
                                              createdAt: end, now: end)
        #expect(sameDay.dailyAverage == nil)
    }

    @Test("相同仓库更新元数据后总数和描述必须原地更新")
    func sameRepositoryMetadataUpdateRebuildsCard() async {
        let snapshot = Self.snapshot(state: .fresh)
        let repository = ReadmeStarHistoryRepositoryStub(cachedSnapshot: snapshot, refreshSnapshot: snapshot)
        let viewModel = ReadmeStarHistoryViewModel(repository: repository, projectVisibilityProvider: { _ in .public })
        var repo = Self.repo()
        await viewModel.loadIfNeeded(repo: repo, databaseScopeRevision: 1, locale: Locale(identifier: "en"))
        let revision = viewModel.renderState.revision
        repo.starsCount = 50_511
        repo.description = "Description from updated metadata"
        await viewModel.loadIfNeeded(repo: repo, databaseScopeRevision: 1, locale: Locale(identifier: "en"))
        #expect(viewModel.renderState.revision != revision)
        #expect(viewModel.renderState.html?.contains("<strong>50.5K</strong>") == true)
        #expect(viewModel.renderState.html?.contains("Description from updated metadata") == true)
    }

    @Test("README 从创建日起画，补点不能给缺历史的老仓制造增长数据", arguments: ["2020-01-01", "2026-07-22"])
    func creationAnchorIsOnlyUsedForDrawing(createdDay: String) async throws {
        let created = try #require(StarHistoryDateCodec.date(from: createdDay))
        let first = try #require(StarHistoryDateCodec.date(from: "2026-08-18"))
        let last = try #require(StarHistoryDateCodec.date(from: "2026-09-07"))
        let points = [StarHistoryPoint(date: first, count: 752, source: .githubHistory, precision: .reconstructed),
                      StarHistoryPoint(date: last, count: 1_165, source: .githubHistory, precision: .reconstructed)]
        let snapshot = Self.snapshot(points: points, state: .fresh)
        let repository = ReadmeStarHistoryRepositoryStub(cachedSnapshot: snapshot, refreshSnapshot: snapshot)
        let viewModel = ReadmeStarHistoryViewModel(repository: repository, projectVisibilityProvider: { _ in .public })
        var repo = Self.repo()
        repo.createdAt = createdDay + "T00:00:00Z"
        await viewModel.loadIfNeeded(repo: repo, databaseScopeRevision: 1, locale: Locale(identifier: "en"))
        let html = try #require(viewModel.renderState.html)
        for attribute in ["data-points", "data-rendered"] {
            let prefix = try #require(html.range(of: attribute + "=\""))
            let value = try #require(html[prefix.upperBound...].split(separator: "\"", maxSplits: 1).first)
            let series = try #require(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[Double]])
            #expect(series.first == [created.timeIntervalSince1970 * 1_000, 0])
            #expect(series.last?[1] == 1_165)
        }
        #expect(html.contains(#"class="starcat-star-history-line" points="44.00,280.00 "#))
        if createdDay == "2020-01-01" {
            #expect(html.components(separatedBy: "<strong>—</strong>").count - 1 == 3)
        }
        #expect(snapshot.points == points)
    }

    @Test("描述与 Topics 不可注入脚本，总数不能误用历史最后读数")
    func repositoryFieldsAreEscapedAndTotalUsesMetadata() throws {
        var repo = Self.repo()
        repo.starsCount = 50_511
        repo.description = "<script>alert('description')</script>"
        repo.topics = #"["ai", "<img src=x onerror=bad>", "research", "extra"]"#
        let snapshot = Self.snapshot(state: .cached)
        let model = StarHistoryChartRenderModel(points: snapshot.points, range: .all, repositoryCreatedAt: nil)
        let html = try #require(ReadmeStarHistoryHTMLRenderer.render(
            snapshot: snapshot, model: model, repo: repo, locale: Locale(identifier: "en"),
            context: ReadmeStarHistoryHTMLRenderer.ReadmeStarHistoryRenderContext.prepare(language: Self.repo().language)
        ))
        #expect(html.contains("<strong>50.5K</strong>"))
        // 总星标数字 ticker 的数值来源：元数据原始值，不能用历史曲线最后读数。
        #expect(html.contains(#"data-count="50511""#))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("&lt;img src=x onerror=bad&gt;"))
        #expect(html.contains(">+1</span>"))
    }

    private nonisolated static func points(
        source: StarHistorySource = .githubHistory,
        precision: StarHistoryPrecision = .reconstructed
    ) -> [StarHistoryPoint] {
        [
            StarHistoryPoint(
                date: StarHistoryDateCodec.date(from: "2020-02-01")!,
                count: 10,
                source: source,
                precision: precision,
                fetchedAt: StarHistoryDateCodec.date(from: "2026-09-05")
            ),
            StarHistoryPoint(
                date: StarHistoryDateCodec.date(from: "2026-09-05")!,
                count: 200,
                source: source,
                precision: precision,
                fetchedAt: StarHistoryDateCodec.date(from: "2026-09-05")
            )
        ]
    }

    /// 从卡片 HTML 的属性里取出 JSON 序列（[[epochMillis, count], …]）。
    private nonisolated static func series(_ html: String, attribute: String) throws -> [[Double]] {
        let value = try attributeValue(html, attribute: attribute)
        return try #require(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[Double]])
    }

    /// 标注数组含字符串键值，属性里被 HTML 转义过，解析前要还原。
    private nonisolated static func annotations(_ html: String) throws -> [[String: Any]] {
        let value = try attributeValue(html, attribute: "data-annotations")
        let unescaped = value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return try #require(try JSONSerialization.jsonObject(with: Data(unescaped.utf8)) as? [[String: Any]])
    }

    private nonisolated static func attributeValue(_ html: String, attribute: String) throws -> String {
        let prefix = try #require(html.range(of: attribute + "=\""))
        return String(try #require(html[prefix.upperBound...].split(separator: "\"", maxSplits: 1).first))
    }

    private nonisolated static func snapshot(
        points: [StarHistoryPoint] = points(),
        state: StarHistoryRemoteState
    ) -> StarHistorySnapshot {
        StarHistorySnapshot(
            range: .all,
            points: points,
            remoteState: state,
            coverageStart: points.first?.date,
            updatedAt: points.last?.fetchedAt
        )
    }
}

private actor ReadmeStarHistoryRepositoryStub: RepoStarHistoryRepositoryProtocol {
    private let cachedSnapshot: StarHistorySnapshot
    private let refreshSnapshot: StarHistorySnapshot
    private let refreshGate: ReadmeStarHistoryLoadGate?
    private var cachedRangeValues: [StarHistoryRange] = []
    private var refreshRangeValues: [StarHistoryRange] = []

    init(
        cachedSnapshot: StarHistorySnapshot,
        refreshSnapshot: StarHistorySnapshot,
        refreshGate: ReadmeStarHistoryLoadGate? = nil
    ) {
        self.cachedSnapshot = cachedSnapshot
        self.refreshSnapshot = refreshSnapshot
        self.refreshGate = refreshGate
    }

    func points(repoId: Int64) async throws -> [StarHistoryPoint] { [] }

    func cached(repo: Repo, range: StarHistoryRange) async throws -> StarHistorySnapshot {
        cachedRangeValues.append(range)
        return cachedSnapshot
    }

    func replaceOfficialPoints(repoId: Int64, points: [StarHistoryPoint]) async throws {}

    func refresh(
        repo: Repo,
        range: StarHistoryRange,
        forceRefresh: Bool
    ) async throws -> StarHistorySnapshot {
        refreshRangeValues.append(range)
        await refreshGate?.block()
        return refreshSnapshot
    }

    func cachedRanges() -> [StarHistoryRange] { cachedRangeValues }
    func refreshRanges() -> [StarHistoryRange] { refreshRangeValues }
}

private actor ReadmeStarHistoryLoadGate {
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isReleased = false

    func block() async {
        isBlocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
