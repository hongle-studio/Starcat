//
//  ExternalSearchCredentialTesterTests.swift
//  StarcatTests
//
//  覆盖 External Search API Key 连通性测试的成本与安全边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ExternalSearchCredentialTester")
@MainActor
struct ExternalSearchCredentialTesterTests {
    // 五家服务商共用启用引导，认证模式必须全部遵守“先验证、后保存并启用”。
    @Test("成功时使用固定 credentialTest 请求并保存启用 Provider",
          arguments: ExternalSearchProviderID.allCases)
    func successSavesVerifiedKeyAndEnablesProvider(providerID: ExternalSearchProviderID) async throws {
        let settings = makeSettings()
        let recorder = CredentialTestRecorder()
        let tester = ExternalSearchCredentialTester(
            settings: settings,
            providerFactory: { providerID, _, _ in
                StubCredentialProvider(providerID: providerID, recorder: recorder)
            }
        )

        let outcome = await tester.test(provider: providerID, candidateKey: " test-key ")

        #expect(outcome == .succeeded)
        #expect(recorder.requests == [ExternalSearchRequest(
            query: ExternalSearchCredentialTester.testQuery,
            purpose: .credentialTest,
            maxResults: ExternalSearchCredentialTester.testMaxResults
        )])
        #expect(settings.externalSearchAPIKey(for: providerID) == "test-key")
        #expect(settings.externalSearchSettings(for: providerID).hasVerifiedCredential)
        #expect(settings.externalSearchSettings(for: providerID).isEnabled)
    }

    @Test("失败时不保存候选 Key 且错误详情脱敏",
          arguments: ExternalSearchProviderID.allCases)
    func failureDoesNotSaveCandidateKeyAndRedactsDetails(providerID: ExternalSearchProviderID) async throws {
        let settings = makeSettings()
        settings.setExternalSearchAPIKey("old-key", for: providerID)
        settings.markExternalSearchCredentialVerified(for: providerID)
        var providerSettings = settings.externalSearchSettings(for: providerID)
        providerSettings.isEnabled = false
        settings.setExternalSearchSettings(providerSettings, for: providerID)
        let tester = ExternalSearchCredentialTester(
            settings: settings,
            providerFactory: { providerID, _, _ in
                StubCredentialProvider(
                    providerID: providerID,
                    error: ExternalSearchError.invalidCredential(
                        provider: providerID,
                        statusCode: 401,
                        message: "bad key for who is dong4j"
                    )
                )
            }
        )

        let outcome = await tester.test(provider: providerID, candidateKey: "new-secret-key")

        guard case .failed(let failure) = outcome else {
            Issue.record("Expected failed outcome")
            return
        }
        #expect(settings.externalSearchAPIKey(for: providerID) == "old-key")
        #expect(!settings.externalSearchSettings(for: providerID).hasVerifiedCredential)
        #expect(!settings.externalSearchSettings(for: providerID).isEnabled)
        #expect(failure.friendlyMessage == ExternalSearchError.invalidCredential(provider: providerID, statusCode: 401, message: nil).friendlyMessage)
        #expect(failure.technicalDetails?.contains("httpStatus=401") == true)
        #expect(failure.technicalDetails?.contains("who is dong4j") == false)
        #expect(failure.technicalDetails?.contains("new-secret-key") == false)
    }

    private func makeSettings() -> AppSettings {
        let suite = "ExternalSearchCredentialTesterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, keychain: InMemoryKeychain())
    }
}

private final class CredentialTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExternalSearchRequest] = []

    var requests: [ExternalSearchRequest] { lock.withLock { values } }

    func record(_ request: ExternalSearchRequest) {
        lock.withLock { values.append(request) }
    }
}

private struct StubCredentialProvider: ExternalSearchProvider {
    let providerID: ExternalSearchProviderID
    let recorder: CredentialTestRecorder?
    var error: Error?

    init(
        providerID: ExternalSearchProviderID,
        recorder: CredentialTestRecorder? = nil,
        error: Error? = nil
    ) {
        self.providerID = providerID
        self.recorder = recorder
        self.error = error
    }

    var id: ExternalSearchProviderID { providerID }
    var capabilities: ExternalSearchCapabilities { .capabilities(for: providerID) }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse {
        recorder?.record(request)
        if let error { throw error }
        return ExternalSearchResponse(
            hits: [],
            metadata: ExternalSearchMetadata(provider: providerID)
        )
    }
}
