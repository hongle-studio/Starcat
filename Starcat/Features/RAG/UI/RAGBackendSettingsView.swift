//
//  RAGBackendSettingsView.swift
//  Starcat
//
//  RAG「检索」页中的索引与自托管后端配置。
//
//  关键约束：
//  - SQLite 是零配置默认值，Meilisearch / Qdrant 仅在用户主动选择时显示连接字段。
//  - API Key 继续写入 Keychain，端点与后端选择继续由 `AppSettings` 持久化。
//  - 切换后端不会自动重建索引，只给出明确状态，由用户决定何时执行重建。
//

import SwiftUI

/// 将原 AI 页中的 RAG 后端配置归回 RAG「检索」，避免基础模型设置混入知识库基础设施。
struct RAGBackendSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @State private var isStorageExpanded = false

    @State private var meilisearchAPIKey = ""
    @State private var qdrantAPIKey = ""
    @State private var testingBackends: Set<String> = []
    @State private var meilisearchStatus: RAGBackendTestStatus?
    @State private var qdrantStatus: RAGBackendTestStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("settings.ai.models.embedding.title") {
                let model = settings.resolvedAITask(settings.aiEmbeddingTask, type: .embedding).resolvedModelName
                Text(model.isEmpty ? String.l10n("settings.retrieval.index.noModel") : model)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            KnowledgeRAGIndexSettingsSummary(showsControls: false)
            Divider()
            // 只折叠存储大组；远程连接字段随当前存储直接展开，不再嵌套折叠。
            Button {
                isStorageExpanded.toggle()
            } label: {
                HStack {
                    Text("settings.retrieval.storage.configuration").foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(storageSummary).foregroundStyle(.secondary)
                    Image(systemName: isStorageExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityValue(Text(LocalizedStringKey(isStorageExpanded ? "settings.retrieval.expanded" : "settings.retrieval.collapsed")))
            if isStorageExpanded {
                Text("settings.retrieval.storage.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                storageFields
            }
        }
        .task { loadBackendKeys() }
    }

    private var storageSummary: String {
        let configuration = settings.ragBackendConfiguration
        let keyword = configuration.keywordBackend == .sqliteFTS5 ? "SQLite FTS5" : "Meilisearch"
        let vector = configuration.vectorBackend == .sqlite ? "SQLite BLOB" : "Qdrant"
        return "\(keyword) · \(vector)"
    }

    /// 保留原字段绑定、凭据存储及测试顺序，只改变它们所在的容器。
    private var storageFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("settings.retrieval.storage.keyword")
                    .accessibilityHidden(true)
                Spacer(minLength: 12)
                Picker("settings.retrieval.storage.keyword", selection: keywordBackendBinding) {
                    Text("SQLite FTS5").tag(RAGKeywordBackend.sqliteFTS5)
                    Text("Meilisearch").tag(RAGKeywordBackend.meilisearch)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.vertical, 8)

            if settings.ragBackendConfiguration.keywordBackend == .meilisearch {
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.endpoint", text: meilisearchEndpointBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.index", text: meilisearchIndexBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(
                    titleKey: "settings.services.apiKey",
                    text: $meilisearchAPIKey,
                    isSecure: true
                )
                .padding(.vertical, 8)
                Divider()
                backendActionRow(
                    id: "meilisearch",
                    label: "settings.rag.backends.testAndSave",
                    status: meilisearchStatus
                ) {
                    await testMeilisearch()
                }
                .padding(.vertical, 8)
            }

            Divider()

            HStack(spacing: 12) {
                Text("settings.retrieval.storage.vector")
                    .accessibilityHidden(true)
                Spacer(minLength: 12)
                Picker("settings.retrieval.storage.vector", selection: vectorBackendBinding) {
                    Text("SQLite BLOB").tag(RAGVectorBackend.sqlite)
                    Text("Qdrant").tag(RAGVectorBackend.qdrant)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.vertical, 8)

            Text("settings.retrieval.storage.vectorHint")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.ragBackendConfiguration.vectorBackend == .qdrant {
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.endpoint", text: qdrantEndpointBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.collection", text: qdrantCollectionBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.vectorName", text: qdrantVectorNameBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(
                    titleKey: "settings.services.apiKey",
                    text: $qdrantAPIKey,
                    isSecure: true
                )
                .padding(.vertical, 8)
                Divider()
                backendActionRow(
                    id: "qdrant",
                    label: "settings.rag.backends.testAndSave",
                    status: qdrantStatus
                ) {
                    await testQdrant()
                }
                .padding(.vertical, 8)
            }

            Divider()
            Toggle("settings.rag.backends.fallback", isOn: fallbackBinding)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func backendActionRow(
        id: String,
        label: LocalizedStringKey,
        status: RAGBackendTestStatus?,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            backendStatusLabel(status)
            Spacer(minLength: 8)
            if testingBackends.contains(id) {
                ProgressView()
                    .controlSize(.small)
            }
            Button(label) {
                Task { await action() }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize()
            .disabled(testingBackends.contains(id))
        }
    }

    /// 状态色仅用于图标；正文保持次级色，避免错误文案形成大面积高饱和警示。
    @ViewBuilder
    private func backendStatusLabel(_ status: RAGBackendTestStatus?) -> some View {
        if let status {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: status.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(status.badgeColor)
                    .font(.callout)
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
        }
    }

    private var keywordBackendBinding: Binding<RAGKeywordBackend> {
        Binding(
            get: { settings.ragBackendConfiguration.keywordBackend },
            set: { value in
                var configuration = settings.ragBackendConfiguration
                configuration.keywordBackend = value
                settings.ragBackendConfiguration = configuration
                meilisearchStatus = value == .meilisearch ? .rebuildRequired : nil
            }
        )
    }

    private var vectorBackendBinding: Binding<RAGVectorBackend> {
        Binding(
            get: { settings.ragBackendConfiguration.vectorBackend },
            set: { value in
                var configuration = settings.ragBackendConfiguration
                configuration.vectorBackend = value
                settings.ragBackendConfiguration = configuration
                qdrantStatus = value == .qdrant ? .rebuildRequired : nil
            }
        )
    }

    private var fallbackBinding: Binding<Bool> {
        backendBinding(\.fallbackToSQLite)
    }

    private var meilisearchEndpointBinding: Binding<String> {
        backendBinding(\.meilisearch.endpoint)
    }

    private var meilisearchIndexBinding: Binding<String> {
        backendBinding(\.meilisearch.indexName)
    }

    private var qdrantEndpointBinding: Binding<String> {
        backendBinding(\.qdrant.endpoint)
    }

    private var qdrantCollectionBinding: Binding<String> {
        backendBinding(\.qdrant.collectionName)
    }

    private var qdrantVectorNameBinding: Binding<String> {
        backendBinding(\.qdrant.vectorName)
    }

    private func backendBinding<Value>(
        _ keyPath: WritableKeyPath<RAGBackendConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings.ragBackendConfiguration[keyPath: keyPath] },
            set: { value in
                var configuration = settings.ragBackendConfiguration
                configuration[keyPath: keyPath] = value
                settings.ragBackendConfiguration = configuration
            }
        )
    }

    private func loadBackendKeys() {
        meilisearchAPIKey = (try? KeychainManager.shared.loadAIKey(
            forProvider: RAGBackendConfiguration.meilisearchKeychainID
        )) ?? ""
        qdrantAPIKey = (try? KeychainManager.shared.loadAIKey(
            forProvider: RAGBackendConfiguration.qdrantKeychainID
        )) ?? ""
    }

    private func testMeilisearch() async {
        testingBackends.insert("meilisearch")
        defer { testingBackends.remove("meilisearch") }
        do {
            try KeychainManager.shared.storeAIKey(
                meilisearchAPIKey,
                forProvider: RAGBackendConfiguration.meilisearchKeychainID
            )
            let provider = MeilisearchRAGProvider(
                configuration: settings.ragBackendConfiguration.meilisearch,
                apiKey: meilisearchAPIKey,
                repository: dependencies.ragChunkRepository
            )
            try await provider.testConnection()
            meilisearchStatus = .success
        } catch {
            meilisearchStatus = .failure(error.localizedDescription)
        }
    }

    private func testQdrant() async {
        testingBackends.insert("qdrant")
        defer { testingBackends.remove("qdrant") }
        do {
            try KeychainManager.shared.storeAIKey(
                qdrantAPIKey,
                forProvider: RAGBackendConfiguration.qdrantKeychainID
            )
            let provider = QdrantRAGProvider(
                configuration: settings.ragBackendConfiguration.qdrant,
                apiKey: qdrantAPIKey,
                repository: dependencies.ragChunkRepository
            )
            try await provider.testConnection()
            qdrantStatus = .success
        } catch {
            qdrantStatus = .failure(error.localizedDescription)
        }
    }
}
