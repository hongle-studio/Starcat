//
//  IndexedTextBuilder.swift
//  Starcat
//
//  把 Repo / README / AI 摘要 / 用户笔记拼成 `IndexedSnapshot` 与最终喂模型的字符串。
//  详见 `docs/3-设计/详细设计/26-向量搜索改进.md` § 2 / 3.1。
//
//  模块职责：
//  - `buildSnapshot(repo:readme:summary:note:)` → 拼成结构化快照（落 `snapshot_json`）
//  - `render(snapshot:)` → 把快照拼成 embedding 模型的输入字符串
//
//  关键约束：
//  - **主体拼装**（2026-09-15 修订，取代原决策 D 的互斥三级降级）：
//      1. AI 摘要与 README 都有 → 摘要在前、README 在后，中间空一行
//      2. 只有其中一份 → 用那一份
//      3. 都没有 → 用 `description + topics` 兜底
//    旧逻辑「有摘要就丢掉 README」，Search Center 会漏掉标题/口号类字面查询
//    （例如 README H1 里的 "AI Knowledge Base for macOS"）。摘要仍放前面，
//    因为更短、更稳；README 截断长度仍由调用方传入。
//    无论走哪级，**元数据尾巴和用户笔记永远拼接**（dong4j 2026-06-12：
//    "三级降级策略只适用于自然语言主体，元数据/笔记永远会被拼上"）。
//  - **元数据字段筛选**（决策 D）：保留 fullName / description / language / topics /
//    license / homepage，剔除 stars / forks / owner / name / 时间戳；
//    避免 stars / forks 高频变化引起 diff 永远超阈值。
//  - **buildSnapshot 是 pure 函数**：不读 settings / 不调网络，方便单测；
//    截断长度等可配置项必须由调用方传入。
//  - `render(snapshot:userPromptTemplate:)` 输出的字符串只用于"喂 embedding 模型"，
//    不要再用于 diff 判定（diff 走结构化 snapshot，避免顺序变化误判）。
//  - **render 走占位符渲染**（dong4j 决策 2026-06-14）：embedding 任务有自己独立的
//    占位符命名空间（`{fullName}` / `{description}` / `{language}` / `{topics}` /
//    `{license}` / `{homepage}` / `{body}` / `{notes}`），用户在 Settings 编辑
//    `aiEmbeddingTask.prompt.userPromptTemplate` 时可以自由组合 / 删除占位符。
//    删占位符（甚至连同 label 那一行）= 不注入对应数据。
//

import Foundation

enum IndexedTextBuilder {

    // MARK: - 构建快照

    /// 把 repo 元数据 + 数据源拼成 `IndexedSnapshot`。
    ///
    /// - Parameters:
    ///   - repo: 仓库基础信息（必须）
    ///   - readmePlainText: 已经过 `ReadmePreprocessor.process(html:/markdown:)` 处理的纯文本；
    ///     调用方负责清洗与截断。传 nil 表示没有可用 README。
    ///   - aiSummary: AI 摘要的 Markdown 文本（如果用户已生成过）；传 nil 表示无摘要。
    ///   - noteContent: 用户私有笔记的 Markdown 文本；传 nil / 空串表示无笔记。
    static func buildSnapshot(
        repo: Repo,
        readmePlainText: String?,
        aiSummary: String?,
        noteContent: String?
    ) -> IndexedSnapshot {
        let body = chooseBody(
            aiSummary: aiSummary,
            readmePlainText: readmePlainText,
            repo: repo
        )
        let notes = normalizeOptional(noteContent)
        let metadata = IndexedSnapshot.Metadata(
            fullName: repo.fullName,
            description: normalizeOptional(repo.description),
            language: normalizeOptional(repo.language),
            topics: normalizeTopics(repo.topics),
            license: normalizeOptional(repo.license),
            homepage: normalizeOptional(repo.homepage)
        )
        return IndexedSnapshot(body: body, notes: notes, metadata: metadata)
    }

    // MARK: - 渲染最终字符串

    /// 把 snapshot 按 `userPromptTemplate` 渲染成 embedding 模型的输入字符串。
    ///
    /// **占位符约定**（仅 embedding 任务局部命名空间）：
    /// - `{fullName}` → `snapshot.metadata.fullName`
    /// - `{description}` → `snapshot.metadata.description ?? ""`
    /// - `{language}` → `snapshot.metadata.language ?? ""`
    /// - `{topics}` → `snapshot.metadata.topics ?? ""`（已是 `"a, b, c"` 形式）
    /// - `{license}` → `snapshot.metadata.license ?? ""`
    /// - `{homepage}` → `snapshot.metadata.homepage ?? ""`
    /// - `{body}` → `snapshot.body`（摘要 + README 并存后的主体，可为空字符串）
    /// - `{notes}` → `snapshot.notes ?? ""`
    ///
    /// **空数据**：dict 里有 key 但 value 是空字符串 → 替换为空（label / 换行保留）；
    /// 模板中删占位符那行（连同 label）→ 输出根本不渲染对应内容。
    /// 模板中写了不在 dict 中的占位符 → 保留 `{xxx}` 字面量（对齐 `AIPromptConfiguration.render`
    /// 的 fail-loud 语义，便于发现写错的 key）。
    ///
    /// **不做空行清理**：如果用户的 template 让某个占位符渲染为空导致连续空行，
    /// 不做 squeeze。原因：① 用户的 template 是用户的，service 不偷偷改格式；
    /// ② embedding 模型对空白容忍，几个空行不影响向量质量。
    static func render(snapshot: IndexedSnapshot, userPromptTemplate: String) -> String {
        let placeholders: [String: String] = [
            "fullName": snapshot.metadata.fullName,
            "description": snapshot.metadata.description ?? "",
            "language": snapshot.metadata.language ?? "",
            "topics": snapshot.metadata.topics ?? "",
            "license": snapshot.metadata.license ?? "",
            "homepage": snapshot.metadata.homepage ?? "",
            "body": snapshot.body,
            "notes": snapshot.notes ?? ""
        ]
        return AIPromptConfiguration.render(template: userPromptTemplate, placeholders: placeholders)
    }

    // MARK: - 私有：主体拼装

    /// 选取主体：摘要与 README 并存，都没有才用 description+topics 兜底。
    ///
    /// 摘要放前面，是因为它短且经过用户确认，语义更稳；README 保留标题、口号、
    /// 功能列表，否则向量和 snapshot 字面加分都看不见这些句子。
    /// 兜底层不附加 "Description: ..." 前缀（防止跟元数据尾巴重复）。
    /// 如果连这两个都为空，body 就是空字符串，metadata 单独承担描述性。
    private static func chooseBody(
        aiSummary: String?,
        readmePlainText: String?,
        repo: Repo
    ) -> String {
        let summary = normalizeOptional(aiSummary)
        let readme = normalizeOptional(readmePlainText)
        switch (summary, readme) {
        case let (summary?, readme?):
            return summary + "\n\n" + readme
        case let (summary?, nil):
            return summary
        case let (nil, readme?):
            return readme
        case (nil, nil):
            var parts: [String] = []
            if let desc = normalizeOptional(repo.description) {
                parts.append(desc)
            }
            let topics = repo.topicsArray
            if !topics.isEmpty {
                parts.append(topics.joined(separator: ", "))
            }
            return parts.joined(separator: "\n")
        }
    }

    // MARK: - 私有：归一化

    /// `nil` / 空白字符串统一变 `nil`，避免 `Optional<String>("")` 与 `Optional<String>.none`
    /// 在 `IndexedSnapshot.Metadata` Equatable 比较时被判定为不等。
    private static func normalizeOptional(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// 把 `repos.topics`（JSON 数组字符串）归一化为 "a, b, c" 形式，方便：
    /// 1. metadata diff 比较稳定（不受 JSON whitespace 影响）
    /// 2. embedding 模型读到逗号分隔列表，比裸 JSON 更自然
    /// 解析失败时回退到原始字符串。
    private static func normalizeTopics(_ topicsJSON: String?) -> String? {
        guard let topicsJSON = normalizeOptional(topicsJSON) else { return nil }
        guard let data = topicsJSON.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            return topicsJSON
        }
        let normalized = array
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return normalized.isEmpty ? nil : normalized.joined(separator: ", ")
    }
}
