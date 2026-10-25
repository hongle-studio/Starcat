//
//  KnowledgeRAGIndexSettingsSummary.swift
//  Starcat
//
//  检索设置与索引管理共用真实索引摘要。读取数据库覆盖率不触发索引构建；
//  重建和暂停仅出现在管理页，并继续调用原索引器入口。
//

import SwiftUI

/// 共享状态投影，防止检索页和管理页对同一轮构建给出不同的统计含义。
struct KnowledgeRAGIndexSettingsSummary: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale
    let showsControls: Bool

    @State private var coverage: RAGIndexStatusProjection?
    @State private var coverageError: String?
    @State private var refreshRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(indexStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let coverage {
                Text(String(
                    format: String.l10n("settings.retrieval.index.coverage"),
                    locale: locale,
                    Int64(coverage.indexedRepoCount), Int64(coverage.knowledgeRepoCount), Int64(coverage.readyChunks)
                ))
            }
            // 摘要页将管理入口与向量状态并排，长备注允许换行，按钮保持原生尺寸。
            HStack(alignment: .center, spacing: 8) {
                if let coverage {
                    Text(String(
                        format: String.l10n("settings.retrieval.index.issues"),
                        locale: locale,
                        Int64(coverage.pendingChunks), Int64(coverage.failedChunks), Int64(coverage.staleChunks)
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                } else if let coverageError {
                    Text("settings.retrieval.index.loadFailed")
                        .help(coverageError)
                } else {
                    ProgressView().controlSize(.small)
                }
                if !showsControls {
                    Spacer(minLength: 8)
                    Button("settings.retrieval.index.manage") {
                        NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.knowledgeIndex")
                    }
                    .fixedSize()
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            if showsControls {
                HStack {
                    Spacer(minLength: 8)
                    if dependencies.knowledgeRAGIndexBuilder.status.isActivelyIndexing {
                        Button("settings.rag.index.pause") {
                            dependencies.knowledgeRAGIndexBuilder.cancel()
                        }
                    } else {
                        Button {
                            dependencies.knowledgeRAGIndexBuilder.startRebuild()
                        } label: {
                            Label("settings.rag.index.rebuild", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .task(id: refreshRevision) { await refreshCoverage() }
        .onChange(of: dependencies.knowledgeRAGIndexBuilder.status) { _, _ in
            refreshRevision += 1
        }
        .onChange(of: settings.resolvedAITask(settings.aiEmbeddingTask, type: .embedding).resolvedModelName) { _, _ in
            refreshRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .knowledgeRAGIndexDidChange)) { _ in
            refreshRevision += 1
        }
    }

    /// 状态计数沿用索引器语义；FTS 可检索片段不冒充当前模型的向量覆盖率。
    private var indexStatusText: String {
        switch dependencies.knowledgeRAGIndexBuilder.status {
        case .idle:
            return String.l10n("settings.rag.index.idle")
        case .fetchingReadmes(let processed, let total):
            return String(format: String.l10n("settings.rag.index.readmesFormat"), locale: locale, processed, total)
        case .building(let processed, let total):
            return String(format: String.l10n("settings.rag.index.reposFormat"), locale: locale, processed, total)
        case .embedding(let processed, let total):
            return String(format: String.l10n("settings.rag.index.chunksFormat"), locale: locale, processed, total)
        case .completed(let coverage):
            return String(format: String.l10n("settings.rag.index.readyFormat"), locale: locale, coverage.readyChunks)
        case .failed(let message):
            return message
        }
    }

    /// 视图离开或新一轮刷新会取消旧读取，避免过期快照覆盖更新后的数据库统计。
    @MainActor
    private func refreshCoverage() async {
        do {
            let snapshot = try await dependencies.knowledgeRAGIndexBuilder.coverage()
            guard !Task.isCancelled else { return }
            coverage = snapshot
            coverageError = nil
        } catch {
            guard !Task.isCancelled else { return }
            coverageError = error.localizedDescription
            coverage = nil
        }
    }
}
