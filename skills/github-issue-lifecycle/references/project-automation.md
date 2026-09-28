# Project 自动同步

本能力把 Issue 生命周期同步到已配置的 GitHub Project。Issue 仍是任务事实来源；Project 只负责汇总、排期和状态可视化。

## 配置边界

仓库与 organization 映射位于 `project-profiles.json`。脚本优先使用 `repositories[OWNER/REPO]` 的精确配置，未命中时回退到 `organizations[OWNER]`。每个 profile 只保存稳定名称和 Project 编号，不保存 Project、field 或 option 的 GraphQL ID。脚本每次运行时动态解析 ID，避免看板重建或选项调整后继续写入旧 ID。

仓库和其 owner 均未配置时，不会被自动加入任何 Project。脚本以成功状态退出，并明确输出 `skipped`；Issue 生命周期继续执行。

GitHub Project 的 built-in `Auto-add to project` workflow 在 UI 中按单一 repository 选择范围，不能用一个 workflow 覆盖整个 organization。organization profile 解决的是 Skill 调用路径：只要 Issue 通过本 Skill 创建或继续流转，脚本就会把任意已配置 organization 仓库的 Issue 加入 Project。若用户绕过 Skill 直接在支撑仓库创建 Issue，需要为该仓库另建 UI workflow，或在下次 Skill 调用时补同步。

## Shell 入口

```bash
scripts/project-sync.sh \
  --repo starcat-app/Starcat \
  --issue 62 \
  --phase implementation_started \
  --work-type Feature \
  --area RAG
```

批量迁移或补录多个 Issue 时，使用 `project-bulk-sync.sh`，避免逐 Issue 重复全量读取 Project 而耗尽 GraphQL 配额：

```bash
scripts/project-bulk-sync.sh --manifest issues.json
```

`issues.json` 是 JSON 数组，每项包含 `repo`、`issue`，并可包含 `phase`、`status`、`workType`、`area`。一次调用中的所有项必须映射到同一个 Project。脚本先通过 REST 验证 Issue，再只读取一次 Project 字段和 item 列表，批量写入后统一回查；支持 `--dry-run` 和 `--profile`。

主要参数：

- `--repo OWNER/REPO`：必填，必须与 profile 完全匹配。
- `--issue NUMBER`：必填，只接受正整数。
- `--phase PHASE`：可选，从 profile 映射为 Status。
- `--status STATUS`：可选，直接设置 Status；不能与 `--phase` 同时使用。
- `--work-type VALUE`：可选，按 Project 中的准确选项设置 `Work Type`。
- `--area VALUE`：可选，按 Project 中的准确选项设置 `Area`。
- `--dry-run`：完成认证、Issue、Project、字段和分页读取，只报告计划写入，不修改远端。
- `--wait-seconds N`：覆盖 profile 的自动添加等待时间。
- `--profile PATH`：使用其他仓库映射文件，便于复用脚本。

脚本故意不提供 `--priority`。Priority 属于人工产品决策，不能从 title、label 或代码路径自动推断。

## 幂等与分页

`gh project item-list --limit <itemLimit>` 会由 GitHub CLI 自动翻页。脚本同时比较返回 item 数量与 `totalCount`；达到 limit 而没有拿全时立即失败，防止因为漏页而重复添加 item。

执行顺序：

1. 确认 `gh`、`jq` 和 GitHub 认证。
2. 确认准确的 Issue URL。
3. 读取 Project 和所有字段。
4. 分页查找同一 Issue URL 对应的 item。
5. 等待 Project 自带的 auto-add workflow；超时后用 `gh project item-add` 补入。
6. 读取当前字段值，只更新发生变化的字段。
7. 等待 Project workflow 稳定后再次读取，必要时补写一次并验证最终值。

重复调用不会创建重复 item，也不会重复更新已经相同的字段。

## 元数据规则

- `Work Type` 只在 Issue 类型明确时设置为 `Bug`、`Feature`、`Refactor` 或 `Chore`。
- `Area` 只在模块明确且 Project 存在准确选项时设置。
- 语义含糊时不传参数，并在报告中保留为空，不能让 Agent 静默猜测。
- 脚本按准确名称匹配 single-select option；字段或选项缺失、重复、类型错误时停止对应同步。

## 故障语义

Project 操作和 Issue 操作是相互独立的可观察步骤。Project 同步失败时：

- 不撤销已经创建、评论或关闭成功的 Issue。
- 不回滚本地代码变更。
- 明确报告失败阶段、Issue 状态和 Project 未同步状态。
- 保持调用幂等，修复权限或配置后可以安全重试。

GitHub 公开的 `gh project` 与 GraphQL mutation 目前不能创建或启用 Project V2 built-in workflow。因此，Skill 调用期间的状态流转由本脚本全自动完成；用户在 Skill 之外直接重新打开 Issue 时，需要在 Project UI 中启用 `Item reopened → Backlog`，否则下次运行 Skill 时再由 `reopened` 阶段完成校正。
