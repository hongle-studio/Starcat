//
//  ManageDetailContent.swift
//  Starcat
//
//  R-01「三场景共用架构」Manage 详情页 ContentView 插槽。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2 & §5.1）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Manage 详情 = `RepoDetailScaffold` (Hero + RepoLocalSections) + `ManageDetailContent` (body slot)
//
//  本 ContentView 负责 body slot 内容：
//  - `ReadmeStateView`：README WebView + 内嵌 cacheFooter（翻译/刷新按钮）
//  - 洞察切换抽到 `RepoDetailInsightsHost`：跟探索 / Trending / 周刊 / 动态共用，
//    门禁只看 `Repo.isStarred`，不再绑死 Manage 模块。
//
//  R-01 v1.5 修订（2026-06-10 下午, dong4j bug 反馈）：
//  - tags / notes / release 三段（`RepoLocalSections`）**从 ContentView 迁回 Scaffold
//    metadataPanel 内**,跟随 hero 整段折叠让位 README 阅读区;
//  - 本 ContentView 不再渲染 `RepoLocalSections`,body 仅剩 `ReadmeStateView`;
//  - 4 场景的三段调用 100% 同构,Scaffold 内置消除重复(详见 `RepoDetailScaffold.swift`
//    文件头 v1.5 修订段)。
//
//  R-01 v2.1 修订（2026-06-11 晚, dong4j bug 反馈「右下角多了一个一模一样的刷新图标」）：
//  - 撤销 P0-E（2026-06-10）的「Scaffold overlay 浮动刷新按钮」设计 §3.2.9。
//  - 原 §3.2.9 给 Scaffold 加 `onRefresh:` 入参,Manage 详情通过它在 bottomTrailing
//    overlay 出一个浮动 `SyncIconButton` 触发 `viewModel.reloadItems(forceRefresh: true)`;
//    但 `ReadmeStateView.cacheFooter` **始终**也渲染一个同款 `SyncIconButton`(只刷
//    README) → Manage 视觉上同位置叠两个一样的图标,用户分不清职责差异,反馈为 bug。
//  - 修复方向(dong4j 选 A:合并):cacheFooter 内那个按钮在 Manage 场景**同时**刷
//    README + reloadItems。本 ContentView 注入 `HomeViewModel`,onRetry 闭包先发
//    `readmeVM.reload(...)`(内部 fire-and-forget Task),再 `Task { await viewModel.reloadItems }`,
//    两个动作并行不阻塞 UI。Trending / Activity / Weekly 的 ContentView 不变(本来就只
//    刷 README,符合各自语义)。
//  - 关键约束:① cacheFooter 按钮 tooltip 仍是 `readme.refresh`,文案没改——避免影响
//    其他 3 个共用 `ReadmeStateView` 的场景;Manage 场景下事实上扩展到「整页刷新」是
//    合理的(用户在详情页点刷新自然期望全刷),不引入额外按钮分裂 UI。② Scaffold 同步
//    删除 `onRefresh` 参数 + overlay,详见 `RepoDetailScaffold.swift` 文件头 v2.1 修订段。
//
//  滚动 → 折叠：把 ReadmeStateView 的 `onScrollReportChange` 上报到 Scaffold
//  传入的 `onScrollReport` closure,由 Scaffold 内部换算成 collapse progress,
//  Scaffold 的 metadataPanel（含 hero + RepoLocalSections）整段同步折叠。
//
//  ────────────────────────────────────────────────────────────────────────────
//  环境依赖
//  ────────────────────────────────────────────────────────────────────────────
//
//  - `ReadmeViewModel`：README 加载状态机
//  - `ReadmeTranslationViewModel`：翻译状态机（HOM-68）
//  - `AppSettings`：翻译目标语言等
//  - `AuthSession`：未登录时 README 不能显示完整内容（私有仓库）
//  - `HomeViewModel`：v2.1 起 onRetry 内调 `reloadItems(forceRefresh: true)` 用
//

import SwiftUI

/// README Star History 预加载身份。
///
/// 完整 Repo 参与身份可覆盖同仓星标数、描述和 Topics 更新；手动刷新 revision 则确保
/// README 返回 304、文档指纹未变化时，历史摘要仍能重新走一次 cache-first 校验。
private struct ReadmeStarHistoryPreloadIdentity: Hashable {
    let repo: Repo
    let databaseScopeRevision: UInt64
    let localeIdentifier: String
    let manualRefreshRevision: UInt64
}

/// Manage 场景详情页的 body 内容（README + 翻译入口）。
struct ManageDetailContent: View {

    let repo: Repo

    /// 由 Scaffold 注入：把 scroll offset 上报回去用于驱动顶部面板折叠。
    let onScrollReport: (RepoDetailScrollReport) -> Void

    @Environment(ReadmeViewModel.self) private var readmeVM
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession
    @Environment(AppDependencies.self) private var dependencies
    /// v2.1（2026-06-11）：onRetry 闭包同时刷 README + 整个 repo 视图数据(缓存 repo +
    /// tags + notes + release 计数等)。详见文件头 v2.1 修订段。
    @Environment(HomeViewModel.self) private var viewModel
    @Environment(\.locale) private var locale
    @State private var readmeStarHistoryViewModel: ReadmeStarHistoryViewModel?
    @State private var readmeStarHistoryTask: Task<Void, Never>?
    @State private var readmeStarHistoryManualRefreshRevision: UInt64 = 0

    var body: some View {
        RepoDetailInsightsHost(
            repo: repo,
            onScrollReport: onScrollReport,
            onLeaveReadme: cancelReadmeStarHistory
        ) {
            // v1.5 修订（2026-06-10）：RepoLocalSections 已迁回 Scaffold metadataPanel，
            // README 继续直接上报滚动，让 hero 折叠行为保持不变。
            ReadmeStateView(
                state: readmeVM.state,
                contentScope: .manage(repoId: repo.id),
                // 统一构造带末尾 `/` 的目录 URL，避免 WebKit 把 HEAD 当文件名后丢掉分支段。
                baseURL: URL(string: repo.htmlUrl).map(ReadmeWebView.repositoryContentBaseURL),
                onScrollReportChange: onScrollReport,
                translationControl: ReadmeTranslationControl(
                    repo: repo,
                    translationVM: translationVM,
                    settings: settings
                ),
                // 同仓同步把 Star 数降为零时，本帧就撤下旧卡；异步任务随后清理状态机。
                starHistoryRenderState: repo.starsCount > 0
                    ? (readmeStarHistoryViewModel?.renderState ?? .empty)
                    : .empty,
                onApproachingBottom: startReadmeStarHistoryFallbackIfNeeded
            ) {
                refreshReadmeAndRepo()
            } onLogin: {
                // 2026-06-29：只弹登录 sheet，不强制走 Device Flow。
                authSession.requestLoginSheet()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: readmeStarHistoryPreloadIdentity) {
                // 与 README 自身并行预加载。SwiftUI 会在退出 README、切仓或身份变化时
                // 自动取消任务；Repository 仍可完成已共享的请求并把结果写入 SQLite。
                await preloadReadmeStarHistoryIfNeeded()
            }
        }
        .onChange(of: repo.id) { _, _ in
            cancelReadmeStarHistory()
        }
        .onChange(of: dependencies.databaseScopeRevision) { _, _ in
            // 同一个 repo id 在账号切换后属于另一份数据库，旧摘要不能跨作用域复用。
            cancelReadmeStarHistory()
        }
        .onDisappear {
            cancelReadmeStarHistory()
        }
    }

    /// v2.1 既有语义保持不变：Manage 的 README 刷新同时重读当前 repo 视图数据。
    private func refreshReadmeAndRepo() {
        // 用户主动刷新 README 时让摘要重新走 cache-first + 后台校验；旧 HTML 会随文档重载清掉。
        cancelReadmeStarHistory()
        readmeStarHistoryManualRefreshRevision &+= 1
        readmeVM.reload(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
        Task { await viewModel.reloadItems(forceRefresh: true) }
    }

    private var readmeStarHistoryPreloadIdentity: ReadmeStarHistoryPreloadIdentity {
        ReadmeStarHistoryPreloadIdentity(
            repo: repo,
            databaseScopeRevision: dependencies.databaseScopeRevision,
            localeIdentifier: locale.identifier,
            manualRefreshRevision: readmeStarHistoryManualRefreshRevision
        )
    }

    /// README 模式首帧即启动 cache-first 加载；零 Star 在创建 ViewModel 前短路。
    private func preloadReadmeStarHistoryIfNeeded() async {
        guard repo.starsCount > 0 else {
            readmeStarHistoryViewModel?.cancel()
            return
        }
        let historyViewModel: ReadmeStarHistoryViewModel
        if let readmeStarHistoryViewModel {
            historyViewModel = readmeStarHistoryViewModel
        } else {
            let created = ReadmeStarHistoryViewModel(
                repository: dependencies.repoStarHistoryRepository,
                projectVisibilityProvider: { repoID in
                    (try? await dependencies.userProjectRepository.fetchProject(repoID: repoID))?.visibility
                }
            )
            readmeStarHistoryViewModel = created
            historyViewModel = created
        }

        await historyViewModel.loadIfNeeded(
            repo: repo,
            databaseScopeRevision: dependencies.databaseScopeRevision,
            locale: locale
        )
    }

    /// document-end 的接近底部信号仅作兜底；ViewModel 的身份去重保证不会产生第二次请求。
    private func startReadmeStarHistoryFallbackIfNeeded() {
        guard repo.starsCount > 0 else { return }
        readmeStarHistoryTask?.cancel()
        readmeStarHistoryTask = Task {
            await preloadReadmeStarHistoryIfNeeded()
        }
    }

    /// 原始 `Task` 不随 SwiftUI 状态机自动取消；切仓时必须先停任务，再让 generation 失效。
    private func cancelReadmeStarHistory() {
        readmeStarHistoryTask?.cancel()
        readmeStarHistoryTask = nil
        readmeStarHistoryViewModel?.cancel()
    }
}
