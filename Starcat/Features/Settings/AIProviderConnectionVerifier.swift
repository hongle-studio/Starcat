//
//  AIProviderConnectionVerifier.swift
//  Starcat
//
//  服务商连接验证的无持久化步骤。新增弹窗和既有配置重测共用同一模型发现规则，
//  验证期间不写 Keychain、AppSettings 或任务绑定；调用方确认会话仍有效后才保存。
//

import Foundation

/// 将待验证配置转换为已发现模型的配置快照，不负责保存或切换当前服务商。
@MainActor
enum AIProviderConnectionVerifier {
    /// 复用现有客户端的模型发现与 Anthropic 路径探测，避免额外发送一次连接测试。
    static func verify(
        profile: AIProviderProfile,
        apiKey: String,
        referencedModelNames: Set<String> = []
    ) async throws -> AIProviderProfile {
        try Task.checkCancellation()
        let client = try AIClientFactory.make(configuration: AIClientConfiguration(
            providerID: profile.id,
            provider: profile.provider,
            apiKey: apiKey,
            baseURL: profile.baseURL,
            chatModel: profile.models.first(where: { $0.capability == .chat })?.name
                ?? profile.provider.defaultChatModel,
            embeddingModel: profile.models.first(where: { $0.capability == .embedding })?.name
                ?? profile.provider.defaultEmbeddingModel,
            timeoutInterval: 60
        ))
        let models = try await client.listModels()
        try Task.checkCancellation()

        var verified = profile
        if let anthropic = client as? AnthropicClient {
            verified.baseURL = anthropic.probedBaseURL
        }
        verified.mergeDiscoveredModels(models, referencedModelNames: referencedModelNames)
        verified.isEnabled = true
        verified.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
        verified.lastTestStatus = .success(modelCount: verified.models.count)
        return verified
    }
}
