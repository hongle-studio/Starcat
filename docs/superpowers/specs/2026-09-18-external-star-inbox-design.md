# 外部新增星标提示（中栏胶囊）设计

> 状态: 已讨论确认（2026-09-18）
> 范围: 星标 → 全部仓库；前台探测外部新增 star；点击后再走现有增量同步
> 非目标: Unstar 提示、元数据变化提示、后台/最小化探测、其它侧边栏分类、自动写库

## 1. 背景与目标

在浏览器或手机上 star 某个仓库时，Starcat 不会立刻知道。中栏已有 `StarsSyncButton`，但必须人手点刷新，列表才会出现新仓库。

目标是复刻 X 时间线上「有新内容」胶囊的认知，而不是再做一条写库路径：

- 前台定时看远端有没有本地还没有的新 star
- 有才在「全部仓库」列表上浮出胶囊
- 点胶囊（或点现有刷新按钮）才执行真正的增量同步

**本迭代目标**

- App 在前台且已登录时，每 15 秒探测一次 GitHub `/user/starred` 第一页
- 只提示外部新增的 star；队列跨探测轮次累加，直到用户确认同步
- 胶囊只出现在「星标 → 全部仓库」
- 点击后复用 `SyncManager.performFullSync` 增量路径，不另写 upsert

**明确不做**

- 外部 unstar、仓库描述 / star 数等元数据变化
- App 最小化或未运行时的后台探测
- 标签 / 语言 / 未分类 / GitHub Lists / 其它页面的胶囊
- 探测阶段把新仓库写入 `repos` 表
- 把探测 ETag 写进同步状态，导致点击后 304 早退
- 系统通知、Dock 角标

## 2. 产品决策（已锁定）

| 项 | 决策 |
|----|------|
| 发现 vs 写入 | 先提示，点了才同步。探测不写本地仓库列表 |
| 什么算更新 | 只认外部新增 star（远端有、本地 `is_starred` 没有） |
| 探测时机 | App 在前台就轮询；胶囊仍只出现在「全部仓库」 |
| 间隔 | 15 秒；进入前台立刻打一次，再按 15 秒重复 |
| 胶囊内容 | 无箭头；owner 头像叠放；最多 3 个；超出用 `+N` |
| 队列 | 跨 15 秒探测累加；最新在前；点同步成功后清空 |
| 位置 | 浮在列表上方正中，盖住最上面一两行，不改列表高度 |
| 动画 | 出现、消失、头像从 1 个增到多个都要过渡；减少动态效果时只保留透明度 |
| 写入 | 点胶囊或点 `StarsSyncButton`，都走现有增量同步 |
| 持久化 | 队列只活在内存；进程被杀即丢，启动仍走现有 stale 自动同步 |

## 3. 架构

```text
App 前台 + 已登录
        │
        ▼
 ExternalStarInbox（探测服务，内存队列 + 探测专用 ETag）
        │  每 15s  GET /user/starred?page=1
        │  If-None-Match = 探测 ETag（禁止写 SyncManager ETag）
        │
        ├─ 304 / 无新 ID  → 不变
        ├─ 新 ID          → 按「最新在前」追加队列（id + owner 头像）
        └─ 失败           → 静默，下一轮再试

「全部仓库」中栏
        │
        └─ 队列非空 → ExternalStarInboxCapsule 浮层
                         │
                         ▼ 点击
                   SyncManager.performFullSync
                         │
                         ├─ 成功 → 按本地 ID 清空队列 + 消失动画
                         └─ 失败 → 队列保留，胶囊留下
```

### 3.1 职责拆分

| 单元 | 职责 | 不做什么 |
|------|------|----------|
| `ExternalStarInbox` | 前台 15 秒探测、累加队列、停探门控、同步成功后清队列 | 不写 `repos`、不改 `lastSyncAt`、不改同步 ETag |
| `SyncManager` | 点击后的增量同步（现有路径） | 不负责发现提示 |
| `ExternalStarInboxCapsule` | 「全部仓库」列表上的浮层 UI | 不发起第二套写库 |
| `RepoListView` | 仅在 `selection == .allStars` 且队列非空时叠放胶囊 | 其它分类不出现 |

探测服务挂在 `AppDependencies`，与 `SyncManager` 并列。前台节奏用进程内定时循环（`Task.sleep` + `NSApplication` 激活态），**不要**复用 `GitHubNotificationPoller`：那条是 30 分钟档的 `NSBackgroundActivityScheduler`，语义不同。

测试 host（`TestEnvironment.isRunning`）不启动循环。

### 3.2 探测请求

- 端点：现有 `GitHubAPIClient.starredRepos(page: 1, perPage: 100, ifNoneMatch:)`
- 排序已经是 `sort=created&direction=desc`，第一页就是最近 star
- `If-None-Match` 只用 inbox 自己的内存 ETag
- 200 时更新探测 ETag；**同步表 `starsETag` 保持不动**
- 对比用 `RepoRepository.fetchStarredRepoIDs()`，不把整表 `Repo` 拉进内存

新 ID 判定（整批插入，避免逐条 prepend 把同一轮的顺序反转）：

```text
remotePage = 第一页（接口顺序，最新在前）
localIDs   = 本地 is_starred
pendingIDs = 当前队列

newItems = remotePage 中 id 不在 localIDs 且不在 pendingIDs 的项（保持远端顺序）
队列     = newItems + 旧队列
```

例：队列已有 `[A]`，下一轮第一页是 `[B, A, …]` → 新项只有 `B` → `[B, A]`。同一轮同时看到 `B` 和 `A` 则一次得到 `[B, A]`。

队列项最小字段：`repoID`、`ownerLogin`、`avatarURL`、`starredAt`。只为胶囊渲染和去重服务。头像 URL 缺失时走 `RemoteAvatar` 既有占位，不挡进队。

### 3.3 硬约束：探测 ETag 与同步 ETag 隔离

这是本设计最容易写错的点。

`SyncManager` 在非 force 增量同步时，会用本地 `starsETag` 做 page 1 条件请求。304 会直接早退、不写库。

如果探测把这份 ETag 提前更新成「远端最新」，用户点胶囊时就会 304，新仓库进不来。所以：

- 探测 ETag 只存在 `ExternalStarInbox` 内存里
- 探测路径禁止调用 `updateStarsETag` / `updateSyncState` / `upsertStarred`
- 单测必须锁住「探测 200 之后，同步 ETag 仍是旧值」

### 3.4 点击落地

胶囊和顶栏 `StarsSyncButton` 都调用现有 `performFullSync(userID:)`（默认 `force: false`，即增量）。

- 同步开始：胶囊可继续显示，再次点击空操作（`SyncManager` 已拒绝重入）
- 同步成功：丢掉已经出现在本地 starred IDs 里的队列项；通常整队清空，播放消失动画
- 同步失败 / 取消 / 限流：队列不动

应用内 star 不会进队列（本地已有该 ID）。若队列里碰巧有同一 ID，下次探测或同步成功后的清理会丢掉它。

切账号 / 退出登录：立刻清空队列并丢弃探测 ETag。

## 4. UI

只出现在 Manage 中栏、`SidebarItem.allStars`、队列非空。

- 叠在列表区域 `ZStack` 上，水平居中、贴列表顶部，盖住最上面一两行
- **不**插入 `listWithOptionalBanner` 那种会把列表往下推的横幅
- 顶栏排序 / 上次同步 / `StarsSyncButton` 不被挡住，也不被替换
- 只有胶囊接收点击；周围仍是列表滚动和选行

视觉：

- 胶囊底：`Color.accentColor`（Starcat accent `#007AFF`，不搬 X 的青色）
- `+N` 文字：白色（DESIGN.md `on-accent`）
- 无箭头
- owner 圆头像，复用 `RemoteAvatar`，最新在最前、轻微重叠
- 1 / 2 / 3 条：只叠头像
- 4 条：3 头像 + `+1`
- 5 条：3 头像 + `+2`
- 按钮：`.buttonStyle(.plain)` + `.focusEffectDisabled()`
- Hover：只改亮度，不改布局尺寸
- Help / VoiceOver：i18n，例如「N 个新星标，点击同步」

动画：

| 场景 | 正常 | 减少动态效果 |
|------|------|----------------|
| 出现 | 0.25s easeOut，透明度 0→1，轻微下移约 8pt | 只做透明度 |
| 消失 | 0.20s easeOut，透明度 1→0，轻微上移约 8pt | 只做透明度 |
| 队列 1→N | 胶囊宽度和叠放跟随过渡，不能瞬间跳宽 | 瞬时切到终态，不做位移 |

不做弹跳、弹簧、闪烁。同步成功清空队列后走消失动画，不要直接 `if` 掉视图。

切到其它侧边栏项时立刻卸掉胶囊，不播消失动画（中栏内容已经整体替换）。队列仍保留；切回「全部仓库」且尚未同步时，再走出现动画。

## 5. 边界

| 场景 | 行为 |
|------|------|
| 探测失败（网络 / 5xx / 解码） | 静默；队列维持；不同步按钮变失败；不发系统通知 |
| 正在同步 | 停探 |
| 限流 | 停探；限流解除后再恢复 |
| 未登录 / 窗口不在前台 | 停探 |
| 测试 host | 不启动循环 |
| 15 秒内连续外部 star | 队列累加，最新头像在前 |
| 第一页以外的新 star | 本迭代不探测；留给手动刷新。正常使用新 star 一定在第一页 |
| Unstar / 元数据变化 | 不提示 |
| 进程被杀 | 内存队列丢失；启动走现有 `performFullSyncIfStale` |
| 点胶囊时已在同步 | no-op |

GitHub 已登录 REST 额度约 5000/小时。15 秒一次约 240/小时，且多数 304。停探门控在同步、限流、后台时生效，避免和正式同步抢同一端点。

## 6. 测试

用 `MockGitHubAPIClient`，不打真网。核心 suite 建议 `ExternalStarInboxTests`。

必须覆盖：

1. 304 → 队列空；同步 ETag / `lastSyncAt` 不被探测改写
2. 第一次探测到 A → 队列 `[A]`；不应用、第二次看到 B → `[B, A]`；已在队列中的 ID 不重复
3. 本地已 `is_starred` 的远端仓库不进队列
4. 探测 200 后，仓储里的 `starsETag` 仍是探测前的旧值
5. 模拟增量同步成功 → 队列清空；失败 → 队列保留
6. 同步中 / 限流 / 未登录 / `TestEnvironment.isRunning` → 探测 no-op
7. 切账号 → 队列和探测 ETag 一起清空
8. 展示算法纯函数：1/2/3 只出头像；4 → 3 + `+1`；5 → 3 + `+2`

不做：真机 15 秒轮询、系统通知、Unstar 提示、超过 100 条新 star 的专门用例。

## 7. 实现时落点（名称可微调，职责不能调）

- `Starcat/Core/Sync/ExternalStarInbox.swift`：探测、队列、门控
- `Starcat/Shared/Components/ExternalStarInboxCapsule.swift`：胶囊视图
- `Starcat/Features/Home/RepoListView.swift`：仅全部仓库叠放
- `Starcat/App/AppDependencies.swift`：创建并启动（测试 host 跳过）
- `StarcatTests/ExternalStarInboxTests.swift`
- `Localizable.xcstrings`：无障碍 / help 文案（按 i18n 规范插入，禁止整文件格式化）

`SyncManager` 的写库逻辑本迭代不改；如需「同步完成清理队列」，用现有 `onSyncCompleted` 或观察 `state == .completed`，不要把 inbox 织进 `runSync` 内部。

## 8. 后续（明确不做进本迭代）

- App 最小化后的 `NSBackgroundActivityScheduler` 探测
- 其它中栏分类的同类胶囊
- 外部 unstar 提示（需要全量对比，成本不同）
- 胶囊点击后滚到列表顶部 / 高亮新仓库
- 把待同步队列持久化到 SQLite
