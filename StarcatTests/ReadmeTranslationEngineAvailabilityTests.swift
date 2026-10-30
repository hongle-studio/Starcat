//
//  ReadmeTranslationEngineAvailabilityTests.swift
//  StarcatTests
//
//  AI 翻译引擎可用性回归（2026-09-12 用户反馈）：免 Key 服务商（内置 localAI /
//  ollama / lmStudio）不能因为 Keychain 无 Key 而从默认引擎列表里消失。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("ReadmeTranslationEngineAvailability")
struct ReadmeTranslationEngineAvailabilityTests {

    private func makeSettings(provider: AIServiceProvider, profileID: String) -> AppSettings {
        let defaults = UserDefaults(suiteName: "engine-avail-\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: "engine-avail-\(UUID().uuidString)")
        let settings = AppSettings(defaults: defaults)
        var profile = AIProviderProfile(
            id: profileID,
            provider: provider,
            lastTestStatus: .success(modelCount: 1))
        profile.models = [AIModelDescriptor(
            providerID: profileID, name: "test-chat-model", capability: .chat, isEnabled: true)]
        settings.aiProviderProfiles = [profile]

        var translation = settings.aiTranslationTask
        translation.providerID = profileID
        translation.modelID = "test-chat-model"
        settings.aiTranslationTask = translation
        return settings
    }

    @Test("内置 localAI 无 Key 也应视为已配置（AI 引擎出现）")
    func localAIWithoutKeyIsConfigured() throws {
        let settings = makeSettings(provider: .localAI, profileID: LocalAIModelCatalog.builtInProfileID)
        #expect(ReadmeTranslationEngineAvailability.isAIConfigured(
            settings: settings, keychain: InMemoryKeychain()))
    }

    @Test("ollama / lmStudio 免 Key 同样视为已配置")
    func keylessRemoteProvidersAreConfigured() {
        for provider in [AIServiceProvider.ollama, .lmStudio] {
            let settings = makeSettings(provider: provider, profileID: "test-\(provider.rawValue)")
            #expect(ReadmeTranslationEngineAvailability.isAIConfigured(
                settings: settings, keychain: InMemoryKeychain()))
        }
    }

    @Test("需要 Key 的服务商无 Key 时仍不可用")
    func keyedProviderWithoutKeyUnavailable() throws {
        let settings = makeSettings(provider: .deepSeek, profileID: "test-deepseek")
        #expect(!ReadmeTranslationEngineAvailability.isAIConfigured(
            settings: settings, keychain: InMemoryKeychain()))
    }
}
