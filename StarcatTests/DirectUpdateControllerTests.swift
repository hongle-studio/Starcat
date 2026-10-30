//
//  DirectUpdateControllerTests.swift
//  StarcatTests
//
//  Direct 自动更新配置门控单测。
//

import Foundation
import Testing
@testable import Starcat

@Suite("DirectUpdateController")
@MainActor
struct DirectUpdateControllerTests {

    @Test("Direct 更新通道默认使用正式版")
    func directUpdateChannelDefaultsToStable() {
        let preferences = makePreferences()
        let controller = DirectUpdateController(
            bundle: directBundle,
            preferences: preferences
        )

        #expect(controller.updateChannel == .stable)
        #expect(controller.updateChannel.feedURL.absoluteString == "https://starcat.ink/appcast.xml")
    }

    @Test("Direct 更新通道持久化开发版选择")
    func directUpdateChannelPersistsDevelopmentSelection() {
        let preferences = makePreferences()
        let controller = DirectUpdateController(
            bundle: directBundle,
            preferences: preferences
        )

        controller.selectUpdateChannel(.development)

        #expect(controller.updateChannel == .development)
        #expect(preferences.string(forKey: DirectUpdateChannel.preferenceKey) == "development")
        #expect(controller.updateChannel.feedURL.absoluteString == "https://starcat.ink/appcast-development.xml")
    }

    @Test("非法更新通道偏好回退到正式版")
    func invalidDirectUpdateChannelFallsBackToStable() {
        let preferences = makePreferences()
        preferences.set("preview", forKey: DirectUpdateChannel.preferenceKey)

        let controller = DirectUpdateController(
            bundle: directBundle,
            preferences: preferences
        )

        #expect(controller.updateChannel == .stable)
    }

    @Test("App Store 渠道不能修改 Direct 更新通道")
    func appStoreBuildCannotSelectDirectUpdateChannel() {
        let preferences = makePreferences()
        let bundle = MockDirectUpdateBundle(info: [
            "STARCAT_DISTRIBUTION": "appstore",
            "SUPublicEDKey": "configured"
        ])
        let controller = DirectUpdateController(bundle: bundle, preferences: preferences)

        controller.selectUpdateChannel(.development)

        #expect(controller.updateChannel == .stable)
        #expect(preferences.string(forKey: DirectUpdateChannel.preferenceKey) == nil)
    }

    @Test("App Store 渠道不启用 Direct 更新")
    func appStoreBuildDoesNotExposeDirectUpdater() {
        let bundle = MockDirectUpdateBundle(info: [
            "STARCAT_DISTRIBUTION": "appstore",
            "SUPublicEDKey": "configured"
        ])

        let controller = DirectUpdateController(bundle: bundle)

        #expect(controller.isDirectBuild == false)
        #expect(controller.isConfigured == true)
        #expect(controller.canCheckForUpdates == false)
    }

    @Test("Direct 渠道缺少 Sparkle 公钥时不允许检查更新")
    func directBuildWithoutPublicKeyIsNotConfigured() {
        let bundle = MockDirectUpdateBundle(info: [
            "STARCAT_DISTRIBUTION": "direct",
            "SUPublicEDKey": "   "
        ])

        let controller = DirectUpdateController(bundle: bundle)

        #expect(controller.isDirectBuild)
        #expect(controller.isConfigured == false)
        #expect(controller.canCheckForUpdates == false)
    }

    @Test("Direct 渠道读取非空 Sparkle 公钥")
    func directBuildReadsConfiguredPublicKey() {
        let bundle = MockDirectUpdateBundle(info: [
            "STARCAT_DISTRIBUTION": "direct",
            "SUPublicEDKey": "mock-public-key"
        ])

        let controller = DirectUpdateController(bundle: bundle)

        #expect(controller.isDirectBuild)
        #expect(controller.isConfigured)
    }

    private var directBundle: Bundle {
        MockDirectUpdateBundle(info: [
            "STARCAT_DISTRIBUTION": "direct",
            "SUPublicEDKey": "mock-public-key"
        ])
    }

    private func makePreferences() -> UserDefaults {
        let suiteName = "DirectUpdateControllerTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        preferences.removePersistentDomain(forName: suiteName)
        return preferences
    }
}

private final class MockDirectUpdateBundle: Bundle, @unchecked Sendable {
    private let mockInfo: [String: Any]

    init(info: [String: Any]) {
        self.mockInfo = info
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        mockInfo[key]
    }
}
