# Ambient 系统屏保（Direct `.saver`）设计

> 状态: 已讨论确认（2026-09-17）
> 前置: [`2026-09-03-ambient-album-grid-design.md`](2026-09-03-ambient-album-grid-design.md) 壳 A（App 内 Ambient）已落地；本文件只做当时预留的壳 B
> 范围: Direct 渠道安装真正的 macOS `.saver`；Owner 头像墙；格子只显示图片
> 非目标: App Store 屏保、Repo 场景、屏保叠字、改 App 内 Ambient、空闲自动进入 Ambient

## 1. 背景与目标

App 内 Ambient 已能用 star 过的仓库 / owner 做 Album Artwork 式网格，但只活在 Starcat 窗口里，系统设置的「屏幕保护程序」看不到它。dong4j 要求把这套逻辑做成真正的系统屏保，并且屏保格子只保留图片，不叠项目名或 owner 名称。

**本迭代目标**

- Direct 版提供可安装的 `.saver`，出现在「系统设置 → 屏幕保护程序」
- 素材固定为当前账号 stars 聚合出的 **Owner 头像**
- 运动复用现有 `AmbientGridEngine`：5 行无缝满铺、全局每 3 秒随机单格 Y 轴翻转
- 屏保进程不读主库、不访问 GitHub；只读 App 预先写出的本地快照

**明确不做**

- App Store 渠道的 `.saver` 分发与安装入口
- Repo logo 墙、系统屏保 Options 里切场景
- 屏保格子上的标题、副标题、渐变遮罩文字
- 改 App 内 Ambient（仍 DEBUG、仍叠 `owner/repo` 或 owner 名）
- 启动时静默安装、空闲自动进入 App Ambient
- 屏保 Configure sheet / 可调行数与间隔（沿用 Ambient 默认值）

## 2. 产品决策（已锁定）

| 项 | 决策 |
|----|------|
| 形态 | 真正的 macOS `.saver`，不是 App 内全屏替代 |
| 渠道 | 仅 Direct；App Store 构建不编屏保 target、不显示安装 UI |
| 场景 | 只播 Owner 头像 |
| 格子内容 | 仅 artwork；失败用稳定首字母色块，仍不渲染名字 |
| 入口 | Direct「设置 → 通用 → macOS 集成」：安装 / 更新、已安装时另提供移除 |
| 数据 | App 写 App Group 快照（JSON + 本地头像文件）；屏保只读 |
| 安装位置 | 用户点击后复制到 `~/Library/Screen Savers/` |
| App Ambient | 不改行为、不改入口 |

安装后的使用路径：用户点击安装后，App 会拷贝 `.saver` 并 `open` 它，让系统弹出「为当前用户安装」；然后再到系统设置 → 墙纸 → 屏幕保护程序 → 自定 → 其他 里选择 Starcat。Starcat 不替用户改系统当前屏保。

## 3. 架构

```text
Direct App
  LocalAmbientCatalog(.owners)
        │
        ▼
  ScreensaverSnapshotPublisher ──写入──► Application Support
        │                                  │  screensaver-snapshot-v1.json
        │                                  │  avatars/*.png
        ▼                                  │
  Settings 安装 / 更新 / 移除               │
        │                                  │
        ▼                                  ▼
  ~/Library/Screen Savers/Starcat.saver    ScreensaverSnapshotCatalog
        │                                  │
        └──────── ScreenSaverView ─────────┘
                         │
                  AmbientGridEngine
                         │
                  图片-only SwiftUI 网格
```

### 3.1 继续共用的 Core

只复用 `Starcat/Features/Ambient/Core/`：

- `AmbientGridEngine`、`AmbientCardModel`、`AmbientGridConfig` / `AmbientGridLayout`
- `AmbientCatalogProviding`（屏保侧换成快照实现）
- `AmbientCardFactory.cards(..., scene: .owners)` 仍由 **App** 在发布快照前调用

Core 继续禁止 SwiftUI、`Database.shared`、Kingfisher。

### 3.2 不共用的壳

| 壳 | 目录 | 职责 |
|----|------|------|
| App Ambient | 现有 `Features/Ambient/App/` | 全屏窗口、Kingfisher、标题遮罩；本迭代不改 |
| 系统屏保 | 新 `StarcatScreensaver/` | `ScreenSaverView`、本地 `NSImage`、无标题格子 |

屏保格子不复用 `AmbientCellView` / `AmbientArtworkView`，避免把 Kingfisher 和标题遮罩带进 `legacyScreenSaver` 进程。翻转时序与 App Ambient 相同（0.8s 两段式 Y 轴翻转）。屏保进程读不到 App 的 `starcatReduceMotion`，只尊从系统「减少动态效果」：开启时静态首屏，不创建持续 Timer。

占位色与首字母算法与 App 共用：把 `AmbientArtworkStyle` 的纯函数（paletteIndex / monogram / 目标像素边长）抽到 Core，App 与 `.saver` 各写自己的图片视图。

### 3.3 数据通道

快照写在 Direct 已使用的 Application Support 目录，而不是新 App Group：

`~/Library/Application Support/com.starcat.app/screensaver/`

原因：新 App Group 必须改 Direct 描述文件；当前 `com.starcat.app.direct.debug` profile 不含未登记 group，会直接导致本机构建失败。屏保沙箱通过 home-relative 只读临时例外读取同一目录。

- **不**复用 Widget JSON 文件名，避免两套契约混放
- App Store 的 `Starcat.entitlements` 不增加任何屏保权限

快照布局（容器根目录）：

```text
screensaver-snapshot-v1.json
avatars/<stable-id>.<ext>
```

头像准备规则：

- 8 路并行下载，设置页展示 `completed / total`
- 只复用像素短边 ≥ 460 的图（GitHub 原图常见上限）；列表 32–80px / Widget 小图一律重拉 `s`/`size`=512
- Kingfisher 只在 cache key 就是这份 512 URL、且像素达标时复用

JSON 最小字段：

- `schemaVersion`（v1）
- `generatedAt`
- `userID`（账号切换时旧快照必须失效）
- `cards[]`：`id`、`visualKey`、`title`（只给占位首字母用，UI 不绘制）、`imageFileName`（可选）

写入规则对齐 Widget：同目录临时文件再 `replace` / `move`，避免屏保读到半份 JSON。头像按 `visualKey` 跳过未变化文件。解码边长上限 512px，格式优先已有缓存字节，不把原图常驻内存。

**发布时机（仅 App 写）**

1. Direct 登录成功且本地 stars 可用
2. Stars 同步成功结束
3. 账号切换：先按新 `userID` 发布，再 GC 新集合里不存在的头像文件；登出删除 `screensaver-snapshot-v1.json` 并清空 `avatars/`
4. 用户点击「安装 / 更新」时立刻复制 `.saver`，快照在后台再发布；头像下载不得挡住安装

屏保启动只 `load()` 一次，运行中不追随同步增量（与 Ambient v1 一致）。

## 4. `.saver` 工程与进程约束

- 新 xcodegen target：`StarcatScreensaver`，`WRAPPER_EXTENSION = saver`
- Bundle ID：`com.starcat.app.direct.screensaver`
- 系统设置显示名：`Starcat`
- Principal class：`StarcatScreenSaverView`（`ScreenSaverView` 子类）
- 源文件：`StarcatScreensaver/` + `Starcat/Features/Ambient/Core/`（同一套 Core 编进两个 target）
- 不链 Kingfisher / GRDB / 主 App 源码
- 仅作为 `StarcatDirect` 的嵌入依赖；本机构建会把它放进 `Contents/Resources/StarcatScreensaver.saver`。安装器也会查找 PlugIns 与 `Library/Screen Savers`。
- App Store scheme / `Starcat` target 不依赖该 bundle

屏保跑在系统 `legacyScreenSaver` 进程：

- 禁止打开主库、Keychain、GitHub
- 禁止在屏保进程里下载头像
- 布局始终用 `ScreenSaverView.bounds`，不读 `NSScreen.main`
- Preview 与全屏共用同一套 View，随 bounds 计算行列

空态（无快照、0 张卡）：纯黑底 + 居中 Starcat 应用图标，无说明文案、不崩溃、不进空网格空转。缺单张图：该格用 `AmbientArtworkStyle` 同款稳定色 + 首字母，仍不显示全名。

## 5. 安装 / 更新 / 移除

只出现在 Direct「设置 → 通用 → macOS 集成」现有 Section。App Store 整段隐藏。

| 状态 | 按钮（右对齐，符合设置页按钮规范） | 说明 |
|------|--------------------------------------|------|
| 未安装 | 「安装屏保」 | 发布快照 + 复制 `.saver` |
| 已安装且版本落后于 App 内嵌 bundle | 「更新屏保」 | 覆盖复制；快照一并强制发布 |
| 已安装且版本一致 | 无安装按钮 | 文案说明已安装，可到系统设置中选择 |
| 已安装（任意版本） | 额外「移除屏保」 | 只删 `~/Library/Screen Savers/Starcat.saver` |

约束：

- 复制源是 App 包内已签名的 `.saver`，安装后不得再改 bundle 内容（破坏签名）
- 覆盖安装用同目录临时目录 + replace，避免半个 bundle
- 「移除」不删 App Group 快照，再次安装可立刻有图
- 安装成功不调用系统 API 把 Starcat 设为当前屏保；帮助文案指向系统设置
- 失败保留错误说明，不假装已安装
- 未登录时允许安装 bundle（预览空态图标），但帮助需说明登录并同步 stars 后才会有头像墙

沙箱：Direct 写 `~/Library/Screen Savers/` 若现有 entitlements 不够，只为这一条补最小临时例外，并在实现里写明原因；不得顺手放开无关文件权限。

## 6. 视觉契约（屏保专用）

沿用 Ambient 网格几何，只拿掉文字层：

- 固定深色纯黑；5 行正方形 tile；间距 / 外边距 / 圆角均为 0
- 列数 `ceil(width / tileSide)`，整墙居中，左右允许裁切
- `scaledToFill` 裁切；无底部渐变、无 `Text(title)`
- 无退出按钮（系统屏保由鼠标 / 键盘退出）
- VoiceOver：屏保预览用应用名「Starcat」作为整幅画布标签，不为每格读 owner 名（避免idle 屏保朗读名单）

## 7. 测试计划

- 快照 store：原子写、缺文件、坏 JSON、不支持的 schema、`userID` 不匹配视为空
- Publisher：Owner 聚合与 `AmbientCardFactory` 一致；登出清空；账号切换不泄露旧头像文件（按新集合 GC）
- Installer：安装 / 覆盖更新 / 移除；源缺失失败；不修改 App 包内 bundle
- 屏保 Catalog：只读本地文件组成 `[AmbientCardModel]`，不碰网络
- Engine：现有 `AmbientGridEngineTests` 继续作为运动回归，本迭代不改 Engine API
- 不在单测里启动真实 `legacyScreenSaver`；真机安装与系统设置预览走运行时验收

## 8. 实现分期

1. App Group + 快照模型 / store / publisher + 单测
2. Direct 设置安装器（安装 / 更新 / 移除）+ 发布挂钩
3. `StarcatScreensaver` target：`ScreenSaverView` + 图片-only 网格 + 空态图标
4. `project.yml` / entitlements / xcodegen；Direct 构建嵌入 `.saver`
5. Direct Debug 真机：安装 → 系统设置预览 → 空快照 / 有头像 / Reduce Motion

## 9. 与主进度文档的关系

本功能是 Ambient 壳 B，属 Direct 渠道能力。**未获 dong4j「可以写总览」授权前，不修改 `docs/功能实现总览.md`。** 需要登记时另提勾选文案与 `> 实现:` 草稿。
