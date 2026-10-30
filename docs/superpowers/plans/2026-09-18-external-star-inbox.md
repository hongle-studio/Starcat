# External Star Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 前台每 15 秒探测 GitHub 第一页 starred，把本地还没有的新 star 攒进内存队列，并在「星标 → 全部仓库」中栏浮出头像胶囊；点击后再走现有 `SyncManager` 增量同步。

**Architecture:** 新增 `@Observable` 服务 `ExternalStarInbox` 负责探测、队列和门控，探测 ETag 只活在内存里。`SyncManager` 写库路径不改。胶囊是 `RepoListView` 列表区域的 overlay。同步成功通过现有 `onSyncCompleted` 清队列。

**Tech Stack:** Swift / SwiftUI / `@Observable` / GRDB / `MockGitHubAPIClient` / Swift Testing / Kingfisher `RemoteAvatar`

**Spec:** [`docs/superpowers/specs/2026-09-18-external-star-inbox-design.md`](../specs/2026-09-18-external-star-inbox-design.md)

## Global Constraints

- 禁止改 `docs/功能实现总览.md`，除非 dong4j 明确说可以写总览。
- 禁止改 `SyncManager.runSync` 写库 / ETag / `lastSyncAt` 逻辑。
- 探测路径禁止调用 `updateStarsETag` / `updateSyncState` / `upsertStarred`。
- `TestEnvironment.isRunning` 只挡住 `start()` 的 15 秒循环，不挡住 `poll()`，否则单测无法跑探测。
- 本地还没有 `lastSyncAt` 时不探测，避免首次同步前把整页当成「新 star」闪胶囊。
- 新增 Swift 文件后必须 `xcodegen generate` 再 `make test`。
- `Localizable.xcstrings` 只允许关键词局部插入，保持 `"key" : value`；禁止脚本读写或整文件格式化。
- Commit 格式：`<type>(home): <中文摘要>`，半角冒号，不加句末标点。
- 跑测前关闭 Xcode IDE。单测入口：`make test TEST_ARGS="-only-testing:StarcatTests/ExternalStarInboxTests"`。

## File Structure

| 文件 | 职责 |
|------|------|
| `Starcat/Core/Sync/ExternalStarInbox.swift` | 探测、内存队列、门控、`apply`、同步完成后清理 |
| `Starcat/Shared/Components/ExternalStarInboxCapsule.swift` | 胶囊 UI、头像叠放、出现/消失动画 |
| `StarcatTests/ExternalStarInboxTests.swift` | 展示算法 + 探测/门控/清队列单测 |
| `Starcat/App/AppDependencies.swift` | 创建 inbox，挂 `onSyncCompleted`，切账号清空 |
| `Starcat/App/StarcatApp.swift` | `.environment(dependencies.externalStarInbox)` |
| `Starcat/Shared/Utilities/AppHostEnvironment.swift` | 独立窗口同样注入 |
| `Starcat/Features/Home/HomeView.swift` | 登录后 `start()`，登出 `stop()` |
| `Starcat/Features/Home/RepoListView.swift` | 仅 `allStars` 列表 overlay 胶囊 |
| `Starcat/Resources/Localizable.xcstrings` | help / VoiceOver 文案 |

`project.yml` 已按目录收录 `Starcat/` 与 `StarcatTests/`，不用改 yml，但新文件后要 `xcodegen generate`。

---

### Task 1: 头像槽位纯函数

**Files:**
- Create: `Starcat/Core/Sync/ExternalStarInbox.swift`（先只放 `Item` + `ExternalStarInboxPresentation`）
- Test: `StarcatTests/ExternalStarInboxTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `ExternalStarInbox.Item(repoID:ownerLogin:avatarURL:starredAt:)`
  - `ExternalStarInboxPresentation.Slot.avatar(repoID:ownerLogin:avatarURL:)` / `.overflow(Int)`
  - `ExternalStarInboxPresentation.slots(from:maxAvatars:) -> [Slot]`，默认 `maxAvatars = 3`

- [ ] **Step 1: 写失败单测**

```swift
import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("ExternalStarInbox")
struct ExternalStarInboxTests {

    @Test("1/2/3 pending items render avatars only")
    func presentationAvatarsOnlyWhenAtMostThree() {
        let items = (1...3).map(Self.makeItem)
        let slots = ExternalStarInboxPresentation.slots(from: items)
        #expect(slots.count == 3)
        #expect(slots.allSatisfy { if case .avatar = $0 { true } else { false } })
    }

    @Test("4 items become 3 avatars plus +1")
    func presentationOverflowFour() {
        let slots = ExternalStarInboxPresentation.slots(from: (1...4).map(Self.makeItem))
        #expect(slots.count == 4)
        guard case .overflow(let count) = slots.last else {
            Issue.record("expected overflow slot")
            return
        }
        #expect(count == 1)
    }

    @Test("5 items become 3 avatars plus +2")
    func presentationOverflowFive() {
        let slots = ExternalStarInboxPresentation.slots(from: (1...5).map(Self.makeItem))
        #expect(slots.count == 4)
        guard case .overflow(let count) = slots.last else {
            Issue.record("expected overflow slot")
            return
        }
        #expect(count == 2)
        if case .avatar(let repoID, _, _) = slots[0] {
            #expect(repoID == 1)
        } else {
            Issue.record("newest item should stay first")
        }
    }

    static func makeItem(_ repoID: Int64) -> ExternalStarInbox.Item {
        ExternalStarInbox.Item(
            repoID: repoID,
            ownerLogin: "o\(repoID)",
            avatarURL: "https://avatars.githubusercontent.com/u/\(repoID)",
            starredAt: "2026-09-18T00:00:00Z"
        )
    }
}
```

- [ ] **Step 2: 跑测确认失败**

Run: `make test TEST_ARGS="-only-testing:StarcatTests/ExternalStarInboxTests"`

Expected: `xcodegen` 之后编译失败或 `cannot find ExternalStarInboxPresentation in scope`。

- [ ] **Step 3: 最小实现**

在 `ExternalStarInbox.swift` 先放模型和展示函数（完整 `ExternalStarInbox` class 下一任务再补）：

```swift
import Foundation

struct ExternalStarInboxPresentation {
    enum Slot: Equatable {
        case avatar(repoID: Int64, ownerLogin: String, avatarURL: String?)
        case overflow(Int)
    }

    static func slots(
        from items: [ExternalStarInbox.Item],
        maxAvatars: Int = 3
    ) -> [Slot] {
        let overflow = items.count - maxAvatars
        let avatars = items.prefix(maxAvatars).map {
            Slot.avatar(repoID: $0.repoID, ownerLogin: $0.ownerLogin, avatarURL: $0.avatarURL)
        }
        if overflow > 0 {
            return avatars + [.overflow(overflow)]
        }
        return Array(avatars)
    }
}

extension ExternalStarInbox {
    struct Item: Equatable, Identifiable, Sendable {
        var id: Int64 { repoID }
        let repoID: Int64
        let ownerLogin: String
        let avatarURL: String?
        let starredAt: String
    }
}
```

`ExternalStarInbox` class 可先空壳 `@MainActor @Observable final class ExternalStarInbox {}`，让 extension 能编译。

- [ ] **Step 4: 跑测确认通过**

Run: `xcodegen generate && make test TEST_ARGS="-only-testing:StarcatTests/ExternalStarInboxTests"`

Expected: 3 个 presentation 测试 passed。

- [ ] **Step 5: Commit**

```bash
git add Starcat/Core/Sync/ExternalStarInbox.swift StarcatTests/ExternalStarInboxTests.swift
git commit -m "$(cat <<'EOF'
test(home): 覆盖外部星标胶囊头像槽位算法

EOF
)"
```

---

### Task 2: 探测累加与 ETag 隔离

**Files:**
- Modify: `Starcat/Core/Sync/ExternalStarInbox.swift`
- Modify: `StarcatTests/ExternalStarInboxTests.swift`

**Interfaces:**
- Consumes: `GitHubAPIClientProtocol.starredRepos(page:perPage:ifNoneMatch:)`、`RepoRepositoryProtocol.fetchStarredRepoIDs()` / `fetchStarsETag(userID:)` / `upsertStarred(_:userID:syncedAt:)` / `updateStarsETag(userID:etag:)`
- Produces:
  - `ExternalStarInbox.init(apiClient:repository:syncManager:userIDProvider:isAppActive:)`
  - `func poll() async`
  - `private(set) var pending: [Item]`
  - 探测 ETag 仅 inbox 内存，不写仓储

- [ ] **Step 1: 把探测用例追加进同一 suite**

测试夹具复用 `SyncManagerTests` 的 DTO 拼法。核心断言：

```swift
@Test("304 leaves pending empty and does not rewrite sync ETag")
func pollNotModifiedKeepsSyncETag() async throws {
    let env = try makeEnv()
    try await env.repository.updateStarsETag(userID: 1, etag: "\"sync\"")
    env.api.starredReposHandler = { _, _, _ in
        throw NetworkError.notModified(etag: "\"sync\"")
    }
    await env.inbox.poll()
    #expect(env.inbox.pending.isEmpty)
    #expect(try await env.repository.fetchStarsETag(userID: 1) == "\"sync\"")
}

@Test("new remote IDs accumulate newest first and skip duplicates")
func pollAccumulatesNewIDs() async throws {
    let env = try makeEnv()
    try await seedLastSync(env, userID: 1)
    env.api.starredReposHandler = { _, _, _ in
        env.inbox.pending.isEmpty
            ? env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e1\"")
            : env.onePage([env.makeDTO(id: 11, login: "b"), env.makeDTO(id: 10, login: "a")], etag: "\"e2\"")
    }
    await env.inbox.poll()
    #expect(env.inbox.pending.map(\.repoID) == [10])
    await env.inbox.poll()
    #expect(env.inbox.pending.map(\.repoID) == [11, 10])
}

@Test("locally starred remote IDs never enter pending")
func pollIgnoresLocalStarred() async throws {
    let env = try makeEnv()
    try await seedLastSync(env, userID: 1)
    try await env.repository.upsertStarred([env.makeDTO(id: 10, login: "a")], userID: 1, syncedAt: Date())
    env.api.starredReposHandler = { _, _, _ in
        env.onePage([env.makeDTO(id: 10, login: "a"), env.makeDTO(id: 11, login: "b")], etag: "\"e1\"")
    }
    await env.inbox.poll()
    #expect(env.inbox.pending.map(\.repoID) == [11])
}

@Test("successful probe must not write the sync stars ETag")
func pollMustNotPersistSyncETag() async throws {
    let env = try makeEnv()
    try await seedLastSync(env, userID: 1)
    try await env.repository.updateStarsETag(userID: 1, etag: "\"sync\"")
    env.api.starredReposHandler = { _, _, ifNoneMatch in
        #expect(ifNoneMatch == nil || ifNoneMatch == "\"probe\"")
        return env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"probe\"")
    }
    await env.inbox.poll()
    #expect(try await env.repository.fetchStarsETag(userID: 1) == "\"sync\"")
}
```

`makeEnv()`：`InMemoryDatabaseManager` + `GRDBRepoRepository` + `MockGitHubAPIClient` + `SyncManager(rateLimitBufferSeconds: 0)` + `ExternalStarInbox(userIDProvider: { 1 }, isAppActive: { true })`。

`seedLastSync`：写一条本地 starred，并 `updateSyncState` / 等价方式让 `fetchLastSyncAt(userID:)` 非空。若仓储没有直接 setter，用一次真正的 `performFullSync` 种子（mock 返回已有 DTO）再重置 inbox pending。优先最小路径：调用现有 `updateSyncState(userID:starredCount:syncedCount:status:)` 后确认 `fetchLastSyncAt` 有值。

- [ ] **Step 2: 跑测确认失败**

Expected: `inbox.poll()` 不存在或 pending 行为不符。

- [ ] **Step 3: 实现 `poll()`**

关键约束写进注释：探测 ETag 禁止落到 `updateStarsETag`。合并算法必须整批插入，不能逐条 prepend：

```swift
let newItems = remotePage.compactMap { dto -> Item? in
    let id = dto.repo.id
    guard !localIDs.contains(id), !pendingIDs.contains(id) else { return nil }
    return Item(
        repoID: id,
        ownerLogin: dto.repo.owner.login,
        avatarURL: dto.repo.owner.avatarUrl,
        starredAt: dto.starredAt
    )
}
pending = newItems + pending
```

`poll()` 内部：

1. `guard isAppActive(), let userID = userIDProvider() else { return }`
2. 若 `fetchLastSyncAt(userID:)` 为 nil，return
3. `apiClient.starredRepos(page: 1, perPage: 100, ifNoneMatch: probeETag)`
4. `NetworkError.notModified` → return
5. 其它错误 → 记 `AppLog.sync`，return（不改 pending）
6. 更新 **内存** `probeETag = response.etag`
7. 按上面算法合并

第二次探测要把 `ifNoneMatch` 设为上一轮探测 ETag。

- [ ] **Step 4: 跑测确认通过**

Expected: Task 1 + Task 2 全部 passed。

- [ ] **Step 5: Commit**

```bash
git add Starcat/Core/Sync/ExternalStarInbox.swift StarcatTests/ExternalStarInboxTests.swift
git commit -m "$(cat <<'EOF'
feat(home): 前台探测外部新增星标并累加待同步队列

EOF
)"
```

---

### Task 3: 停探门控

**Files:**
- Modify: `Starcat/Core/Sync/ExternalStarInbox.swift`
- Modify: `StarcatTests/ExternalStarInboxTests.swift`

**Interfaces:**
- Consumes: `SyncManager.isSyncing`、`SyncState.rateLimited`、`userIDProvider`、`isAppActive`
- Produces: `poll()` 在门控命中时零网络；`start()` / `stop()` 仅测试 host 外启动循环

- [ ] **Step 1: 写失败单测**

```swift
@Test("poll is no-op while syncing, rate limited, signed out, or inactive")
func pollGates() async throws {
    let env = try makeEnv()
    try await seedLastSync(env, userID: 1)
    var calls = 0
    env.api.starredReposHandler = { _, _, _ in
        calls += 1
        return env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e\"")
    }

    env.sync.state = .syncing
    await env.inbox.poll()
    env.sync.state = .rateLimited(retryAt: Date().addingTimeInterval(60))
    await env.inbox.poll()
    env.sync.state = .idle

    let signedOut = ExternalStarInbox(
        apiClient: env.api,
        repository: env.repository,
        syncManager: env.sync,
        userIDProvider: { nil },
        isAppActive: { true }
    )
    await signedOut.poll()

    let inactive = ExternalStarInbox(
        apiClient: env.api,
        repository: env.repository,
        syncManager: env.sync,
        userIDProvider: { 1 },
        isAppActive: { false }
    )
    await inactive.poll()

    #expect(calls == 0)
}

@Test("start does not begin looping in the test host")
func startSkippedInTests() {
    let env = try! makeEnv()
    env.inbox.start()
    #expect(env.inbox.isLoopRunning == false)
}
```

`isLoopRunning` 用 `private(set) var isLoopRunning = false` 暴露给测试。

- [ ] **Step 2: 跑测确认失败**

Expected: 未门控时 `calls > 0`，或 `start()` 在测试里拉起循环。

- [ ] **Step 3: 实现门控**

`poll()` 开头增加：

```swift
guard isAppActive() else { return }
guard userIDProvider() != nil else { return }
guard !syncManager.isSyncing else { return }
if case .rateLimited = syncManager.state { return }
```

`start()`：

```swift
func start() {
    guard !TestEnvironment.isRunning else { return }
    guard loop == nil else { return }
    isLoopRunning = true
    loop = Task { [weak self] in
        await self?.poll()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.pollInterval))
            await self?.poll()
        }
    }
}

func stop() {
    loop?.cancel()
    loop = nil
    isLoopRunning = false
}
```

`pollInterval = 15`。`start()` 另外监听 `NSApplication.didBecomeActiveNotification`，回到前台立刻 `poll()`；`stop()` 移除观察者。测试不走这条通知。

- [ ] **Step 4: 跑测确认通过**

- [ ] **Step 5: Commit**

```bash
git add Starcat/Core/Sync/ExternalStarInbox.swift StarcatTests/ExternalStarInboxTests.swift
git commit -m "$(cat <<'EOF'
feat(home): 外部星标探测在同步限流未登录和后台时停探

EOF
)"
```

---

### Task 4: 点击落地与清队列

**Files:**
- Modify: `Starcat/Core/Sync/ExternalStarInbox.swift`
- Modify: `StarcatTests/ExternalStarInboxTests.swift`

**Interfaces:**
- Consumes: `SyncManager.performFullSync(userID:)`、`fetchStarredRepoIDs()`
- Produces:
  - `func apply()`
  - `func handleSyncCompleted() async`
  - `func resetForAccountChange()`

- [ ] **Step 1: 写失败单测**

```swift
@Test("successful incremental sync clears pending that now exist locally")
func syncSuccessClearsPending() async throws {
    let env = try makeEnv()
    try await seedLastSync(env, userID: 1)
    env.api.starredReposHandler = { _, _, _ in
        env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e\"")
    }
    await env.inbox.poll()
    #expect(env.inbox.pending.map(\.repoID) == [10])

    env.api.starredReposHandler = { _, _, _ in
        env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e2\"")
    }
    env.inbox.apply()
    try await waitUntil { env.sync.state.isCompleted }
    await env.inbox.handleSyncCompleted()
    #expect(env.inbox.pending.isEmpty)
}

@Test("failed sync keeps pending")
func failedSyncKeepsPending() async throws {
    let env = try makeEnv()
    try await seedLastSync(env, userID: 1)
    env.api.starredReposHandler = { _, _, _ in
        env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"e\"")
    }
    await env.inbox.poll()
    env.api.starredReposHandler = { _, _, _ in
        throw NetworkError.unauthorized
    }
    env.inbox.apply()
    try await waitUntil { env.sync.state.isFailed }
    await env.inbox.handleSyncCompleted()
    #expect(env.inbox.pending.map(\.repoID) == [10])
}

@Test("account change drops pending and probe ETag")
func resetClearsProbeState() async throws {
    let env = try makeEnv()
    try await seedLastSync(env, userID: 1)
    env.api.starredReposHandler = { _, _, _ in
        env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"probe\"")
    }
    await env.inbox.poll()
    env.inbox.resetForAccountChange()
    #expect(env.inbox.pending.isEmpty)

    var sawIfNoneMatch: String?
    env.api.starredReposHandler = { _, _, ifNoneMatch in
        sawIfNoneMatch = ifNoneMatch
        return env.onePage([env.makeDTO(id: 10, login: "a")], etag: "\"probe2\"")
    }
    await env.inbox.poll()
    #expect(sawIfNoneMatch == nil)
}
```

若 `SyncState` 没有 `isCompleted` helper，测试里直接 `if case .completed = env.sync.state`。`waitUntil` 抄 `SyncManagerTests.waitForState`。

`handleSyncCompleted()` 必须自身判断：只有当前 `syncManager.state` 是 `.completed` 才按本地 ID 过滤；`.failed` / `.idle` / `.rateLimited` 不动队列。这样 AppDependencies 可以无条件转调。

- [ ] **Step 2: 跑测确认失败**

- [ ] **Step 3: 实现**

```swift
func apply() {
    guard let userID = userIDProvider() else { return }
    syncManager.performFullSync(userID: userID)
}

func handleSyncCompleted() async {
    guard case .completed = syncManager.state else { return }
    let local = Set((try? await repository.fetchStarredRepoIDs()) ?? [])
    pending.removeAll { local.contains($0.repoID) }
}

func resetForAccountChange() {
    pending = []
    probeETag = nil
}
```

- [ ] **Step 4: 跑测确认通过**

- [ ] **Step 5: Commit**

```bash
git add Starcat/Core/Sync/ExternalStarInbox.swift StarcatTests/ExternalStarInboxTests.swift
git commit -m "$(cat <<'EOF'
feat(home): 外部星标队列在同步成功或切账号后清空

EOF
)"
```

---

### Task 5: 接入依赖、Environment 与登录生命周期

**Files:**
- Modify: `Starcat/App/AppDependencies.swift`
- Modify: `Starcat/App/StarcatApp.swift`（约 256 行 `.environment(dependencies.syncManager)` 旁）
- Modify: `Starcat/Shared/Utilities/AppHostEnvironment.swift`（约 72 行旁）
- Modify: `Starcat/Features/Home/HomeView.swift` `handleBackgroundPollersAuthChange`（约 1417–1437 行）

**Interfaces:**
- Consumes: Task 2–4 的 `ExternalStarInbox`
- Produces: `AppDependencies.externalStarInbox`；主窗口和独立窗口都能 `@Environment(ExternalStarInbox.self)`

- [ ] **Step 1: 在 `AppDependencies` 声明并创建**

在 `let syncManager: SyncManager` 旁加 `let externalStarInbox: ExternalStarInbox`。

`self.syncManager = SyncManager(...)` 之后立刻创建：

```swift
self.externalStarInbox = ExternalStarInbox(
    apiClient: api,
    repository: repo,
    syncManager: self.syncManager,
    userIDProvider: { [weak session] in
        session?.state.user?.id
    },
    isAppActive: { NSApp.isActive }
)
```

确认 `AuthSession` 用户模型确有 `id: Int64`（与 `performFullSync(userID:)` 同一字段）。

- [ ] **Step 2: 接到同步完成和切账号**

现有 `self.syncManager.onSyncCompleted = { ... }` 闭包捕获列表加入 `externalStarInbox`，末尾：

```swift
await self.externalStarInbox.handleSyncCompleted()
```

用户库切换成功路径（`starredRegistryBootstrapper.reload()` 附近）加：

```swift
self.externalStarInbox.resetForAccountChange()
```

登出（`userId == nil`）同样要 reset。

- [ ] **Step 3: Environment + start/stop**

`StarcatApp.contentRoot` 与 `AppHostEnvironment` 增加：

```swift
.environment(dependencies.externalStarInbox)
```

`HomeView.handleBackgroundPollersAuthChange`：

```swift
if newState.isAuthenticated {
    ...
    dependencies.externalStarInbox.start()
} else {
    dependencies.externalStarInbox.stop()
    dependencies.externalStarInbox.resetForAccountChange()
    ...
}
```

不要接到 `GitHubNotificationPoller` 里。

- [ ] **Step 4: 编译确认**

Run: `xcodegen generate && make test TEST_ARGS="-only-testing:StarcatTests/ExternalStarInboxTests"`

Expected: 单测仍绿；工程能编译（`make build-direct` 若太重，至少 `make test` 能链上新类型）。

- [ ] **Step 5: Commit**

```bash
git add Starcat/App/AppDependencies.swift Starcat/App/StarcatApp.swift \
  Starcat/Shared/Utilities/AppHostEnvironment.swift Starcat/Features/Home/HomeView.swift
git commit -m "$(cat <<'EOF'
feat(home): 接入外部星标探测服务的生命周期

EOF
)"
```

---

### Task 6: 中栏胶囊 UI

**Files:**
- Create: `Starcat/Shared/Components/ExternalStarInboxCapsule.swift`
- Modify: `Starcat/Features/Home/RepoListView.swift` `manageCategoryContent`（约 1484–1514 行的 `Group`）
- Modify: `Starcat/Resources/Localizable.xcstrings`（下一任务可合并；若本任务就要 `Text`，先用 key）

**Interfaces:**
- Consumes: `inbox.pending`、`ExternalStarInboxPresentation.slots`、`RemoteAvatar`、`inbox.apply()`
- Produces: 仅 `viewModel.selection == .allStars && !pending.isEmpty` 时出现的 overlay

- [ ] **Step 1: 胶囊视图**

```swift
struct ExternalStarInboxCapsule: View {
    let items: [ExternalStarInbox.Item]
    let onTap: () -> Void

    @Environment(\.starcatReduceMotion) private var reduceMotion

    private static let appearDuration: TimeInterval = 0.25
    private static let disappearDuration: TimeInterval = 0.20
    private static let move: CGFloat = 8
    private static let avatarSize: CGFloat = 22
    private static let overlap: CGFloat = 8

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: -Self.overlap) {
                ForEach(Array(ExternalStarInboxPresentation.slots(from: items).enumerated()), id: \.offset) { _, slot in
                    slotView(slot)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("list.externalStarInbox.helpFormat \(items.count)"))
        .accessibilityLabel(Text("list.externalStarInbox.helpFormat \(items.count)"))
    }

    @ViewBuilder
    private func slotView(_ slot: ExternalStarInboxPresentation.Slot) -> some View {
        switch slot {
        case .avatar(_, _, let url):
            RemoteAvatar(urlString: url, size: Self.avatarSize, showBorder: true)
        case .overflow(let count):
            Text("+\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .background(Color.accentColor.opacity(0.35), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
        }
    }
}
```

`+N` 文字必须是白色（on-accent）。头像描边在蓝底上用 `RemoteAvatar` 自带 secondary 描边即可；若对比不够，本任务内把 avatar 的 `showBorder` 换成白边 overlay，不要改 `RemoteAvatar` 全局默认。

- [ ] **Step 2: 叠到全部仓库列表，不要改 banner 布局**

在 `manageCategoryContent` 里，给包着列表的 `Group` 加 overlay，**不要**改 `listWithOptionalBanner`，也**不要**盖住 `manageListTopInset`：

```swift
Group {
    // 现有分支保持不动
}
.overlay(alignment: .top) {
    if viewModel.selection == .allStars, !externalStarInbox.pending.isEmpty {
        ExternalStarInboxCapsule(items: externalStarInbox.pending) {
            externalStarInbox.apply()
        }
        .padding(.top, 10)
        .transition(capsuleTransition)
    }
}
.animation(capsuleAnimation, value: externalStarInbox.pending.map(\.repoID))
```

`RepoListView` 增加 `@Environment(ExternalStarInbox.self) private var externalStarInbox`。

动画：

```swift
private var capsuleTransition: AnyTransition {
    if reduceMotion {
        return .opacity
    }
    return .opacity.combined(with: .offset(y: -8))
}

private var capsuleAnimation: Animation? {
    reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.25)
}
```

切到其它 `SidebarItem` 时 `selection == .allStars` 为 false，overlay 直接卸掉，不依赖 transition 完成。切回且队列仍在，再走出现动画。

同步进行中胶囊保持可见；`apply()` / `StarsSyncButton` 都走 `performFullSync`，重入由 `SyncManager` 拒绝。

- [ ] **Step 3: `xcodegen generate` 后编译**

Run: `xcodegen generate && make test TEST_ARGS="-only-testing:StarcatTests/ExternalStarInboxTests"`

Expected: 编译过；UI 无单测，人工看「全部仓库」即可（本任务不要求 computer use）。

- [ ] **Step 4: Commit**

```bash
git add Starcat/Shared/Components/ExternalStarInboxCapsule.swift Starcat/Features/Home/RepoListView.swift
git commit -m "$(cat <<'EOF'
feat(home): 全部仓库中栏浮出外部新增星标胶囊

EOF
)"
```

---

### Task 7: i18n

**Files:**
- Modify: `Starcat/Resources/Localizable.xcstrings`
- Modify: `Starcat/Shared/Components/ExternalStarInboxCapsule.swift`（若 help 的插值语法需改成 `String.l10n`）

**Interfaces:**
- Produces: `list.externalStarInbox.helpFormat`

文案：

| locale | value |
|--------|--------|
| en | `%d new starred repositories. Click to sync.` |
| zh-Hans | `%d 个新星标，点击同步` |

- [ ] **Step 1: 局部插入 Catalog**

在 `"list.filteredRepoCountFormat"` 块结束的 `},` 之后、`"list.lastSyncedFormat"` 之前插入（保持 `"key" : {` 冒号两侧空格）。只写 `en` + `zh-Hans`，不要复制全语言表。

胶囊侧用：

```swift
let text = String(format: String.l10n("list.externalStarInbox.helpFormat"), items.count)
```

`.help(text)` 与 `.accessibilityLabel(text)`。禁止 `String(localized:)`。

- [ ] **Step 2: 自检**

```bash
git diff --stat -- Starcat/Resources/Localizable.xcstrings
# 只能新增，删除必须为 0
jq empty Starcat/Resources/Localizable.xcstrings
rg -n '^[[:space:]]*"list.externalStarInbox.helpFormat" :' Starcat/Resources/Localizable.xcstrings
rg "String\(localized:" Starcat/Shared/Components/ExternalStarInboxCapsule.swift
```

任一项失败：`git checkout -- Starcat/Resources/Localizable.xcstrings` 后停手汇报。

- [ ] **Step 3: Commit**

```bash
git add Starcat/Resources/Localizable.xcstrings Starcat/Shared/Components/ExternalStarInboxCapsule.swift
git commit -m "$(cat <<'EOF'
feat(home): 补充外部星标胶囊的同步提示文案

EOF
)"
```

---

### Task 8: 收口验证

- [ ] **Step 1: 全 suite 相关测试**

```bash
xcodegen generate
make test TEST_ARGS="-only-testing:StarcatTests/ExternalStarInboxTests -only-testing:StarcatTests/SyncManagerTests"
```

Expected: ExternalStarInbox + SyncManager 全绿。SyncManager 行为不变（ETag / 增量路径未被探测改写）。

- [ ] **Step 2: 对照 spec 检查清单**

- 先提示后同步，探测不写 `repos`
- 只提示外部新增 star
- 前台 15 秒；胶囊只在全部仓库
- 无箭头，最多 3 头像，`+N`，队列累加
- 浮层不改列表高度
- 出现 / 消失 / 1→N 有动画；减少动态效果只保留透明度
- 点胶囊或刷新按钮都能清队列
- 探测失败静默
- 未改 `功能实现总览.md`

- [ ] **Step 3: 若有未提交改动，再提交一次修复；没有则跳过**

---

## Self-Review

**Spec coverage**

| Spec 节 | Task |
|---------|------|
| 发现 vs 写入、ETag 隔离 | 2, 4 |
| 只提示新增 star、累加、最新在前 | 2 |
| 前台 15 秒、全部仓库才显示 | 3, 5, 6 |
| 无箭头、3 头像 +N | 1, 6 |
| 浮层位置与动画 | 6 |
| 点击走 SyncManager | 4, 5, 6 |
| 失败静默、门控、切账号 | 2, 3, 4, 5 |
| 测试清单 | 1–4, 8 |
| i18n | 7 |
| 首次未同步不误报 | 2 的 `lastSyncAt == nil` 门控 |

**Type consistency:** `ExternalStarInbox.Item`、`pending: [Item]`、`poll()` / `apply()` / `handleSyncCompleted()` / `resetForAccountChange()` / `start()` / `stop()` 在后续任务中名称保持不变。
