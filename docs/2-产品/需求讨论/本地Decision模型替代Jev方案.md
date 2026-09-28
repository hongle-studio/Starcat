# Starcat 本地 Decision Model 替代 Jev 预研与暂缓方案

> 状态：暂缓，不进入当前开发排期
>
> 记录日期：2026-09-21
>
> 目标：保留以本地 Decision Model 替代或补充 TypeSafe Jev 的产品与技术方案，待开源生态成熟后重新评估；本文不代表已经选型或授权实施。

---

## 1. 背景与当前决定

Starcat 已使用 Jev 为现有 GitHub Lists 和标签执行封闭集判断：应用把仓库事实、README 摘要和候选分组 / 标签组成多个 `noul` 问题，取得每个候选的概率，再交给现有 Policy 做排序、阈值过滤和人工确认。

Jev 需要 API Key 和远程请求。为了让更多用户在不配置第三方服务的情况下使用相同能力，曾考虑增加本地 Decision Model，并复用 Starcat 已有的本地 AI 下载、模型生命周期和 MLX Swift 基础设施。

截至 2026-09-21，相关开源项目出现较快，但仍普遍存在以下一项或多项问题：

- 只有 Python / PyTorch / Python MLX 运行时，不能直接嵌入 Swift App；
- 只是读取普通 LLM 的候选 token logits，并非训练过的决策模型；
- 返回的是候选集合内的相对分数，缺少面向实际正确率的校准；
- 模型过大、上下文过短、语言覆盖不足，或公开评测与 Starcat 场景不一致；
- 项目刚发布，API、模型格式、许可证和维护状态尚不稳定。

**当前决定：暂不集成本地 Decision Model。** Starcat 继续保持现有 Jev 与 LLM 兜底链路，不新增模型类型、依赖、设置项或下载项。后续在成熟候选出现后，按本文门禁重新评估，而不是直接根据项目宣传接入。

---

## 2. 候选项目快照

> 以下是 2026-09-21 的调研快照。该生态变化很快，重新启动时必须核验最新代码、模型卡、许可证、评测和提交状态。

| 候选 | 模型 / 实现 | 本地运行 | MLX 状态 | 当前判断 |
|---|---|---:|---|---|
| [Laya](https://github.com/NandhaKishorM/laya) | 322M / 421M 双向 Encoder，支持 `choice` / `score` / `noul` | 是 | [Laya-MLX](https://github.com/mizorewww/laya-mlx) 为 Python MLX；另有 [Laya-CoreML](https://github.com/mizorewww/laya-coreml) | 当前最值得跟踪，但 Swift 侧仍需移植或适配，且必须在 Starcat 数据上重新校准 |
| [Kev](https://github.com/jaredpalmer/kev) | Qwen3 / Qwen3.5 + LoRA + 专用 pointer head，兼容 `/v1/systemone` | 是 | Apple Silicon 目前主要走 PyTorch / MPS；MLX 后端尚在计划中 | API 与 Jev 最接近，等待 MLX 后端和稳定版本 |
| [Von](https://github.com/wfzyx/von) | 395M ModernBERT 决策模型，兼容 TypeSafe API | 是 | 未提供 MLX | 可作为离线质量对照，不适合当前 Swift 内嵌路径 |
| [OpenJev](https://huggingface.co/AlexWortega/openjev) | Qwen3.5 NLI cross-encoder，输出 entailment / contradiction / neutral | 是 | 未提供 MLX | 语义上适合标签隶属判断，但不是完整 System One API |
| [Bespoke Nimble](https://github.com/bespokelabsai/nimble) | Qwen3.5 9B typed-decision 模型 | 是 | Python MLX | 体积和内存要求过高，不适合作为普惠默认模型 |
| [Verdict](https://github.com/Heman10x-NGU/Verdict-open-jev) | 151M ModernBERT，ONNX / WebGPU | 是 | 无 MLX | 足够小，但公开外部评测与 Jev 差距较大 |
| [NanoJev](https://github.com/TianyuCodings/NanoJev) | Qwen3 0.6B + 决策 head | 是 | 当前以 CUDA 路径为主 | 训练和评测偏游戏决策，不适合直接迁移到仓库标签 |
| [jevmlx](https://github.com/bnsd55/jevmlx) / [LitJev](https://github.com/zhengxuyu/litjev) / [Jevify](https://github.com/Mintzs/jevify) | 普通 LLM 的候选 logits / 约束解码 | 是 | 部分支持 Python MLX | 可用于 baseline 和原型，不应未经校准就把输出称为置信度 |
| [PocketJev](https://github.com/NullPo-jp/PocketJev) | Qwen3-VL + 选项 logits | 是 | 使用 MLX Swift / mlx-swift-lm | 证明 Swift 读取候选 logits 的技术路径可行，但不是训练过的通用决策模型 |
| [LocalJev](https://github.com/githubnext/localjev) | DiffusionGemma 生成概率 JSON | 是 | 依赖 oMLX 和较大模型 | 协议兼容但概率为模型自报，模型过大，不适合 Starcat 默认能力 |

社区汇总入口：[Jev Reproductions Tracker](https://huggingface.co/spaces/multimodalart/jev-reproductions-tracker)。该页面同样明确指出，当前开源项目尚未公开复现 Jev 的 RLCD 训练算法、权重与校准能力。

---

## 3. MLX 可行性边界

“支持 MLX”必须区分三层，后续评审时不得混用：

1. **Python MLX**：能在 Apple Silicon 本地运行，但需要 Python 环境，不能直接作为 Starcat 的 Swift 进程内模型。
2. **MLX Swift / mlx-swift-lm**：可以复用 Starcat 当前运行时、下载器和 Metal 生命周期管理，才是现有架构下优先考虑的内嵌形式。
3. **Core ML**：不是 MLX，但可由 Swift 原生加载，并可使用 GPU / Neural Engine；如果开放模型已经提供经过验证的 Core ML 包，它可能比自行移植到 MLX Swift 风险更低。

Starcat 当前本地模型类型只有 LLM、Embedding、Reranker。未来不能把 Decision Model 伪装成其中任意一种；需要增加独立 `decision` 类型和专用推理容器。普通 Qwen 的 next-token softmax 可以作为技术验证，但在完成领域评测和温度校准前，只能称为“相对分数”，不能称为“正确率”或“可靠置信度”。

---

## 4. 未来接入架构

重新启动时，应先把业务问题构造与 Jev HTTP 传输拆开：

```text
仓库分组 / 标签复用业务
          ↓
SystemOneDecisionProviding
          ├── JevRemoteDecisionProvider
          └── LocalDecisionProvider
```

两种 Provider 共用以下业务语义：

- 仓库事实与 README 状态构造；
- 一个候选分组 / 标签对应一个独立 `noul` 问题；
- 结果合法性检查、排序、阈值过滤和封闭集约束；
- 标签库不足时进入现有 LLM 新标签生成路径；
- AI 建议仍需用户确认，不能因为改成本地模型而扩大自动写入权限。

建议路由顺序：

```text
已安装且启用本地 Decision Model
    → 本地判断

否则，Jev 实验功能已开启且 API Key 可用
    → Jev 远程判断

否则，或现有标签不足
    → 现有 LLM 标签生成 / 分组兜底
```

本地模型与 Jev 必须是可替换 Provider，不能让用户关闭 Jev 后破坏标签生成和自动整理。

---

## 5. 重新启动前的评测门禁

候选模型不能只凭公开 benchmark 入选。必须先建立 Starcat 专用、可重复的离线评测集：

- 用户已确认的仓库与标签关系；
- 用户已确认的 GitHub List 归属；
- 明确不匹配的负样本、近义标签和无匹配样本；
- 英文、中文及中英混合 README；
- 不同候选规模、不同 README 长度和冷启动场景。

至少评估：

- Precision、Recall、F1；
- Brier Score、ECE 和可靠性曲线；
- 自动应用阈值下的误打率与覆盖率；
- 首次加载时间、单仓库延迟、批量吞吐、峰值内存和模型下载体积；
- 候选顺序扰动、近义标签、空标签库和超长 README 的稳定性；
- App Store / Direct 两种构建渠道的模型下载、签名与运行行为。

当前 Jev 路径按字符截取 README，并允许最多 150 个标签候选。若候选模型只有 512 / 1024 token 上下文，必须改为按真实 tokenizer 预算构造状态，并对 Noul 问题分批；分批不能改变最终排序、阈值和去重语义。

---

## 6. 重新评估的启动条件

满足以下条件后，才重新进入方案评审：

1. 至少一个开放权重模型具备稳定的 `noul` / 多标签判断能力，而不只是普通 LLM 自报概率。
2. 提供可嵌入 macOS App 的 MLX Swift、Core ML，或实现成本可控且有一致性测试的开放参考实现。
3. 模型与代码许可证允许 Starcat 商业分发，并能完整登记第三方版权与 NOTICE。
4. 在独立、未参与训练的评测集上公开校准指标、失败边界和可复现结果。
5. 模型体积、内存、上下文和批量延迟适合 Starcat 的普通 Apple Silicon 用户。
6. 项目 API、权重格式和维护状态已稳定，不依赖未合并补丁或临时运行时。
7. Starcat 自有评测证明其在标签复用和仓库分组场景达到可接受门槛。

满足启动条件也只代表可以重新讨论，不代表自动授权实现。

---

## 7. 数据与合规边界

- 训练、微调和校准数据应来自独立人工标注或用户明确确认过的 Starcat 结果。
- 不使用 Jev 输出作为训练、蒸馏或模仿数据。TypeSafe 当前公开协议限制使用其服务或输出训练、开发类似或竞争模型；未来实施前必须重新核验最新条款。
- 不把私人仓库 README、笔记、标签或组织信息上传为公共数据集。
- 发布模型或转换权重前，必须同时核验基础模型、适配器、训练集、转换代码与 tokenizer 的许可证。

参考：[TypeSafe Master Customer Agreement](https://typesafe.ai/legal/mca)。

---

## 8. 本次明确不做

- 不修改 Jev、标签生成、自动整理或仓库分组代码；
- 不新增 `decision` 模型类型、Provider、设置项、数据库字段或下载目录；
- 不引入 Python、ONNX Runtime、Core ML 模型或新的 Swift Package；
- 不下载候选权重，不运行本地模型 benchmark；
- 不把该方案登记为已排期或已完成功能。

