//
//  ReadmeStarHistoryPreview.swift
//  Starcat
//
//  README 末尾 Star History 摘要的数据编排与安全 HTML/SVG 渲染。
//
//  关键约束：
//  - 进入 README 即异步预加载；WebView 的接近底部信号仅作兜底，不能重复发请求。
//  - 先呈现 SQLite 中可用的 GitHub 官方缓存，再复用 Repository 的 ETag / 进程内
//    去重刷新；远端失败不会清空已经显示的缓存曲线。
//  - 无可用缓存时显示同尺寸骨架；零 Star、私有或 Internal 仓库不读取历史、不展示占位。
//  - 只输出固定模板和纯文本转义后的内容，远端字段不能成为标签、属性或脚本。
//  - 全历史在 Snapshot 更新时只建模一次：折线 ≤90 点，悬停/键盘/标注共用一份 ≤400 点
//    的细节序列（data-points 与 data-annotations 的 index 必须同源）；滚动期间不做 O(n) 计算。
//  - 生成在后台线程执行（图标表由主线程预热后传入），输入指纹相同则整段短路；
//    过期结果按请求序号丢弃，切仓/切账号时指纹一并失效。
//  - 头像先复用 Kingfisher 本地缓存，作为图片数据随卡片交给 WebView；缺图下载与历史刷新并行。
//

import Foundation

/// SwiftUI 交给 `ReadmeWebView` 的不可变 DOM 更新状态。
///
/// `revision` 是轻量身份，WebView 用它跳过重复 JavaScript；`html == nil` 表示移除摘要。
/// `prefersAnimatedEntrance` 只在「本仓首张正式卡片」上屏时为 true（骨架 → 曲线的入场帧），
/// 网络刷新、头像晚到触发的重渲染均为 false，避免曲线画完一遍又被原样重画；与
/// `ReadmeTranslation.prefersAnimatedEntrance` 同一模式。Reduce Motion 的 OR 门控
/// （系统偏好 + App 内开关）由 WebView 侧持有，这里只表达「这是一次入场」。
struct ReadmeStarHistoryRenderState: Equatable, Sendable {
    let revision: String
    let html: String?
    let prefersAnimatedEntrance: Bool

    static let empty = ReadmeStarHistoryRenderState(
        revision: "empty",
        html: nil,
        prefersAnimatedEntrance: false
    )
}

/// README 只展示至少两个 GitHub 官方历史点；零 Star 仓库不展示摘要。
enum ReadmeStarHistoryVisibilityPolicy {
    static func shouldDisplay(
        repo: Repo,
        projectVisibility: ProjectVisibility?,
        snapshot: StarHistorySnapshot
    ) -> Bool {
        guard !repo.isPrivate,
              projectVisibility != .private,
              projectVisibility != .internal,
              snapshot.range == .all
        else {
            return false
        }
        return repo.starsCount > 0 && snapshot.points.count >= 2 && snapshot.points.contains {
            $0.source == .githubHistory
        }
    }
}

/// README Star History 的按需状态机。
///
/// SwiftUI 仍持有展示状态；Repository actor 继续作为 SQLite、ETag、请求合并和远端
/// 数据写入的唯一来源。这里不增加第二份业务缓存，只负责 cache-first 上屏与 generation 守门。
@MainActor
@Observable
final class ReadmeStarHistoryViewModel {
    typealias ProjectVisibilityProvider = @Sendable (Int64) async -> ProjectVisibility?

    private struct LoadIdentity: Hashable {
        let repo: Repo
        var repoID: Int64 { repo.id }
        let databaseScopeRevision: UInt64
        let localeIdentifier: String

        var revisionPrefix: String {
            "\(repoID)|\(databaseScopeRevision)|\(localeIdentifier)"
        }
    }

    /// 一次卡片生成的输入指纹。
    ///
    /// 只有真正影响 HTML 的输入才进指纹。`Repo` 与 `StarHistorySnapshot` 都是
    /// Equatable，整值比较既覆盖了当前用到的字段，也不会在将来新增字段时漏项
    /// （手写字段清单一旦漏项，卡片就会停在旧内容上）。`nowDay` 取天粒度：
    /// 指标里的"年龄/窗口天数"本来就只精确到天，同一天内结果必然相同。
    struct RenderFingerprint: Equatable {
        let snapshot: StarHistorySnapshot
        let repo: Repo
        let model: StarHistoryChartRenderModel
        let avatarDataURI: String?
        let localeIdentifier: String
        let nowDay: Int
    }

    private let repository: any RepoStarHistoryRepositoryProtocol
    private let projectVisibilityProvider: ProjectVisibilityProvider
    private var generation: UInt64 = 0
    private var activeIdentity: LoadIdentity?
    private var loadingIdentity: LoadIdentity?
    private var completedIdentity: LoadIdentity?
    private var avatarDataURI: String?
    private var latestSnapshot: StarHistorySnapshot?
    private var isShowingLoading = false
    /// 上一次已生成（或已判定无需生成）的输入指纹，用于短路重复生成。
    private var lastRenderedFingerprint: RenderFingerprint?
    /// 生成请求序号：渲染已经不在主线程，返回时可能已有更新的请求，用它丢弃过期结果。
    private var renderRequestSequence: UInt64 = 0

    private(set) var renderState: ReadmeStarHistoryRenderState = .empty

    init(
        repository: any RepoStarHistoryRepositoryProtocol,
        projectVisibilityProvider: @escaping ProjectVisibilityProvider
    ) {
        self.repository = repository
        self.projectVisibilityProvider = projectVisibilityProvider
    }

    /// WebView 每份文档只触发一次；这里仍按身份去重，防止 SwiftUI 更新重复提交任务。
    func loadIfNeeded(
        repo: Repo,
        databaseScopeRevision: UInt64,
        locale: Locale
    ) async {
        // 调用方会在切仓/切账号时取消 Task；先检查可挡住“已取消但尚未开始”的任务。
        guard !Task.isCancelled else { return }
        let identity = LoadIdentity(
            repo: repo,
            databaseScopeRevision: databaseScopeRevision,
            localeIdentifier: locale.identifier
        )
        if activeIdentity != identity {
            let changesRepository = activeIdentity?.repoID != identity.repoID
                || activeIdentity?.databaseScopeRevision != identity.databaseScopeRevision
            generation &+= 1
            activeIdentity = identity
            loadingIdentity = nil
            completedIdentity = nil
            avatarDataURI = nil
            latestSnapshot = nil
            // 指纹必须跟着身份一起失效：否则"切到别的仓库再切回来"时，输入指纹与
            // 上一次相同会直接短路，而 renderState 已经被清空 —— 卡片就再也不出现了。
            lastRenderedFingerprint = nil
            // 同仓元数据或语言更新时保留旧卡片，避免 SQLite await 期间先移除 DOM 导致滚动跳动。
            if changesRepository {
                renderState = ReadmeStarHistoryRenderState(
                    revision: "\(identity.revisionPrefix)|empty",
                    html: nil,
                    prefersAnimatedEntrance: false
                )
                isShowingLoading = false
            }
        }
        // README 首帧预加载与 WebView 底部兜底可能同时到达；同一身份无论进行中还是
        // 已完成都只执行一次。手动刷新会由调用方重建 ViewModel 状态和 task identity。
        guard loadingIdentity != identity, completedIdentity != identity else { return }

        generation &+= 1
        let requestedGeneration = generation
        loadingIdentity = identity
        defer {
            if generation == requestedGeneration, activeIdentity == identity {
                loadingIdentity = nil
                if Task.isCancelled {
                    // SwiftUI `.task` 离场取消时不能把骨架遗留在仍存活的 WebView；已显示缓存卡则保留。
                    hideLoadingIfNeeded(identity: identity)
                } else {
                    completedIdentity = identity
                }
            }
        }

        // 零 Star 没有需要呈现的曲线；在项目关系、头像、SQLite 和网络之前短路。
        guard owns(requestedGeneration, identity: identity),
              repo.starsCount > 0,
              !repo.isPrivate
        else {
            clearRenderState(identity: identity)
            return
        }
        let visibility = await projectVisibilityProvider(repo.id)
        guard owns(requestedGeneration, identity: identity),
              visibility != .private,
              visibility != .internal
        else {
            clearRenderState(identity: identity)
            return
        }

        // WebView 可能已经显示一个很短的 README；先挂固定骨架，缓存命中后会原地替换。
        // 同仓元数据更新若已有正式卡片则保留旧卡，不退回 loading，避免滚动位置跳动。
        showLoadingIfNeeded(identity: identity)

        // WebKit 不读取 Kingfisher 缓存。先复用列表/详情常用尺寸，再生成带本地图片的首帧 HTML。
        if avatarDataURI == nil {
            let keys = SnapshotAvatarImage.cacheKeys(owner: repo.owner, ownerAvatar: repo.ownerAvatar, displayDiameter: 64)
            let cachedAvatar = await AvatarCacheLoader.cachedDataURI(cacheKeys: keys)
            guard owns(requestedGeneration, identity: identity) else { return }
            avatarDataURI = cachedAvatar
        }

        // 先读持久缓存。即使后续网络较慢或失败，用户到达 README 末尾时也能立即看到旧曲线。
        if let cached = try? await repository.cached(repo: repo, range: .all),
           owns(requestedGeneration, identity: identity) {
            await applyIfVisible(cached, repo: repo, visibility: visibility, identity: identity,
                                 locale: locale, requestedGeneration: requestedGeneration)
        }

        // 两个结构化子任务各自发布就绪结果：曲线不等头像下载，头像也不等 History 网络刷新。
        // 它们继承调用方取消状态，并在写回前核对 generation，避免旧仓库图片覆盖新卡片。
        async let history: Void = refreshHistory(repo: repo, visibility: visibility, identity: identity,
                                                 locale: locale, requestedGeneration: requestedGeneration)
        async let avatar: Void = refreshAvatar(repo: repo, visibility: visibility, identity: identity,
                                               locale: locale, requestedGeneration: requestedGeneration)
        _ = await (history, avatar)
    }

    /// 历史刷新独立于头像请求，仍由 Repository 负责业务缓存与请求去重。
    private func refreshHistory(
        repo: Repo, visibility: ProjectVisibility?, identity: LoadIdentity,
        locale: Locale, requestedGeneration: UInt64
    ) async {
        // Repository 内部继续处理 ETag、304、同仓请求合并与本进程已加载短路。
        // README 摘要不轮询 202，避免用户只是阅读文档时产生持续后台请求。
        guard owns(requestedGeneration, identity: identity) else { return }
        do {
            let refreshed = try await repository.refresh(
                repo: repo,
                range: .all,
                forceRefresh: false
            )
            guard owns(requestedGeneration, identity: identity) else { return }
            await applyIfVisible(refreshed, repo: repo, visibility: visibility, identity: identity,
                                 locale: locale, requestedGeneration: requestedGeneration)
            hideLoadingIfNeeded(identity: identity)
        } catch {
            guard owns(requestedGeneration, identity: identity) else { return }
            // README 底部属于辅助信息；无缓存且远端失败时静默移除骨架，不留下永久 loading。
            hideLoadingIfNeeded(identity: identity)
        }
    }

    /// 只有本地缺图才下载；加载器写回同一份 Kingfisher 缓存，后续浏览可直接复用。
    private func refreshAvatar(
        repo: Repo, visibility: ProjectVisibility?, identity: LoadIdentity,
        locale: Locale, requestedGeneration: UInt64
    ) async {
        guard avatarDataURI == nil, owns(requestedGeneration, identity: identity) else { return }
        let url = GitHubAvatarURL.imageURL(
            from: repo.ownerAvatar ?? RepoAvatarURL.from(owner: repo.owner), displayDiameter: 64
        )
        guard let dataURI = await AvatarCacheLoader.loadAsDataURI(urlString: url?.absoluteString),
              owns(requestedGeneration, identity: identity)
        else { return }
        avatarDataURI = dataURI
        // 使用当前最新快照，避免头像晚到时把已刷新的曲线回退成最初的缓存数据。
        if let snapshot = latestSnapshot {
            await applyIfVisible(snapshot, repo: repo, visibility: visibility, identity: identity,
                                 locale: locale, requestedGeneration: requestedGeneration)
        }
    }

    /// 切仓、切账号或退出 README 模式时只让旧结果失去写回资格。
    ///
    /// 底层 Repository 的共享刷新可能仍会完成并落入 SQLite，供下次进入直接命中缓存。
    func cancel() {
        generation &+= 1
        activeIdentity = nil
        loadingIdentity = nil
        completedIdentity = nil
        avatarDataURI = nil
        latestSnapshot = nil
        isShowingLoading = false
        renderState = .empty
    }

    private func applyIfVisible(
        _ snapshot: StarHistorySnapshot,
        repo: Repo,
        visibility: ProjectVisibility?,
        identity: LoadIdentity,
        locale: Locale,
        requestedGeneration: UInt64
    ) async {
        guard ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: repo,
            projectVisibility: visibility,
            snapshot: snapshot
        ) else { return }

        latestSnapshot = snapshot
        isShowingLoading = false
        let createdAt = repo.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:))
        let model = StarHistoryChartRenderModel(
            points: snapshot.points,
            range: .all,
            repositoryCreatedAt: createdAt
        )
        let now = Date()
        let fingerprint = RenderFingerprint(
            snapshot: snapshot,
            repo: repo,
            model: model,
            avatarDataURI: avatarDataURI,
            localeIdentifier: locale.identifier,
            nowDay: Int((now.timeIntervalSince1970 / 86_400).rounded(.down))
        )
        // 网络刷新拿到同一份数据、头像到达但内容不变时，这次生成没有意义。
        guard fingerprint != lastRenderedFingerprint else { return }
        // 入场判定必须在指纹写回之前取：当前指纹为 nil 说明本仓还没有任何正式卡片
        // （骨架或空态），这次上屏就是「曲线首次出现」的那一帧，值得播生长动画；
        // 之后缓存 → 网络刷新、头像晚到的重渲染指纹非 nil，一律静默替换。
        let prefersAnimatedEntrance = lastRenderedFingerprint == nil

        renderRequestSequence &+= 1
        let sequence = renderRequestSequence
        // AppKit 材料（图标、语言色）只能在主线程先取好；render 本身是纯计算。
        let context = ReadmeStarHistoryHTMLRenderer.ReadmeStarHistoryRenderContext.prepare(language: repo.language)
        let avatar = avatarDataURI
        let html = await Task.detached(priority: .utility) {
            ReadmeStarHistoryHTMLRenderer.render(
                snapshot: snapshot,
                model: model,
                repo: repo,
                locale: locale,
                now: now,
                avatarDataURI: avatar,
                context: context
            )
        }.value

        // 生成期间可能已经有更新的请求或切了仓库：过期结果直接丢弃，由新请求负责写回。
        guard sequence == renderRequestSequence,
              owns(requestedGeneration, identity: identity)
        else { return }
        lastRenderedFingerprint = fingerprint
        // 描述、Topics、覆盖水位变化也必须更新；相同 HTML 不重复触碰 DOM 和 hover 状态。
        guard let html, renderState.html != html else { return }
        renderState = ReadmeStarHistoryRenderState(
            revision: "\(identity.revisionPrefix)|\(UUID().uuidString)",
            html: html,
            prefersAnimatedEntrance: prefersAnimatedEntrance
        )
    }

    private func showLoadingIfNeeded(identity: LoadIdentity) {
        guard renderState.html == nil else { return }
        isShowingLoading = true
        renderState = ReadmeStarHistoryRenderState(
            revision: "\(identity.revisionPrefix)|loading",
            html: ReadmeStarHistoryHTMLRenderer.renderLoading(),
            prefersAnimatedEntrance: false
        )
    }

    private func hideLoadingIfNeeded(identity: LoadIdentity) {
        guard isShowingLoading else { return }
        clearRenderState(identity: identity)
    }

    private func clearRenderState(identity: LoadIdentity) {
        latestSnapshot = nil
        isShowingLoading = false
        lastRenderedFingerprint = nil
        renderState = ReadmeStarHistoryRenderState(
            revision: "\(identity.revisionPrefix)|empty",
            html: nil,
            prefersAnimatedEntrance: false
        )
    }

    private func owns(_ requestedGeneration: UInt64, identity: LoadIdentity) -> Bool {
        !Task.isCancelled && generation == requestedGeneration && activeIdentity == identity
    }
}
