# Anthropic 与 CC Switch 导入专项 Checklist

> 状态: 进行中（实现已落地，审查进行中）
> 创建: 2026-09-14
> 基线: `dev@9ccf5c62`
> 实施分支: `feature/anthropic-cc-switch-import`
> Worktree: `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-anthropic-cc-switch`
> 设计: `docs/3-设计/详细设计/68-Anthropic服务商详细设计.md`、`docs/3-设计/详细设计/69-CC-Switch导入Provider详细设计.md`

## 1. 目标

为 Starcat「设置 → AI」增加 Anthropic Messages API 服务商，以及从本机 CC Switch 数据库一次性导入 BYOK Provider。永远新增 Profile，不覆盖已有 Key / URL / 模型 / 任务绑定。

## 2. Git 与工程边界

- [x] 基于本地 `dev` 创建独立 worktree 与 `feature/anthropic-cc-switch-import`，不占用 `dev` checkout。
- [x] 登记 `BRANCH.md`。
- [x] 不 push。
- [x] 不改 `docs/功能实现总览.md`（除非 dong4j 另行确认）。
- [x] 不执行打包 / 发布脚本。

## 3. Anthropic Messages API（文档 68）

- [x] `AIServiceProvider.anthropic` 追加在 `localAI` 之后，补齐全部 switch。
- [x] `supportsEmbeddingEndpoint = false`；Embedding 任务下拉不含该类型。
- [x] `AnthropicEndpoint`：保留 `/anthropic` path，只按 `/v1` 规则拼 messages / models。
- [x] `AnthropicMessagesCodec`：历史 tool 合并、jsonObject 强制 tool、`max_tokens` 钳制。
- [x] `AnthropicClient`：chat / SSE / listModels / 401 不回落目录 / embedding 拒绝。
- [x] `AIClientFactory` 对 `.anthropic` 构造 `AnthropicClient`。
- [x] `AIUsagePricing.providerAlias("anthropic")` 别名。
- [x] 设置页能新增 Anthropic，默认 URL `https://api.anthropic.com`。

## 4. CC Switch 导入（文档 69）

- [x] `POSIXHome` 用 `getpwuid`，文案路径不含沙盒 `Containers`。
- [x] `CCSwitchConfigStore` 只读打开 sqlite / SQL dump。
- [x] `CCSwitchCredentialExtractor` 按 app_type 抽 Key / URL，跳过 OAuth 与占位符。
- [x] `CCSwitchProviderMapper` 覆盖 anthropicAvailable true / false。
- [x] 设置页导入按钮在 `+` 左侧，确认后串行 `testAndFetchModels`。
- [x] 显示名 `cc-switch: ` 前缀，冲突追加 ` 2`。
- [x] Catalog 按行插入 en + zh-Hans。

## 5. 测试

- [x] `AnthropicEndpointTests`
- [x] `AnthropicMessagesCodecTests`
- [x] `AnthropicClientTests`（含 401 / models 404 ping / embedding 拒绝 / 取消）
- [x] `POSIXHomeTests`
- [x] `CCSwitchConfigStoreTests`
- [x] `CCSwitchCredentialExtractorTests`
- [x] `CCSwitchProviderMapperTests`

## 6. 多轮审查

- [ ] 第一轮：架构与协议边界
- [ ] 第二轮：UI / i18n / 导入安全
- [ ] 第三轮：单测与失败路径
- [ ] 第四轮：文档、Checklist、提交历史一致性
- [ ] 最终结果报告

## 7. 提交约束

- [ ] 每完成一个小功能提交一次，commit message 使用中文。
- [ ] 格式 `<type>(<scope>): <中文摘要>`。
- [ ] 不带入原 `dev` 工作区的未提交改动。
