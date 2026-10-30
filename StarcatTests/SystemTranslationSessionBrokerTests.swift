//
//  SystemTranslationSessionBrokerTests.swift
//  StarcatTests
//
//  系统翻译宿主生命周期回归测试。
//
//  这些测试不调用真实 Apple Translation 语言包，而是验证 Broker 的关键约束：
//  同一进程内只能有一个有效宿主、空批次必须在进入 Translation framework 前失败，
//  以及同一语言对连续激活时 Configuration.version 必须持续递增。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("SystemTranslationSessionBroker")
struct SystemTranslationSessionBrokerTests {

    @Test("多个窗口同时存活时只保留一个翻译宿主 owner")
    func keepsOneHostOwner() {
        let broker = SystemTranslationSessionBroker()
        let mainHost = UUID()
        let detailHost = UUID()

        broker.registerHost(mainHost)
        broker.registerHost(detailHost)

        #expect(broker.registeredHostCountForTesting == 2)
        #expect(broker.activeHostIDForTesting == mainHost)

        broker.unregisterHost(detailHost)

        #expect(broker.registeredHostCountForTesting == 1)
        #expect(broker.activeHostIDForTesting == mainHost)
    }

    @Test("当前 owner 消失后翻译宿主所有权转移到仍存活的窗口")
    func transfersHostOwnershipAfterOwnerDisappears() {
        let broker = SystemTranslationSessionBroker()
        let mainHost = UUID()
        let detailHost = UUID()

        broker.registerHost(mainHost)
        broker.registerHost(detailHost)
        broker.unregisterHost(mainHost)

        #expect(broker.registeredHostCountForTesting == 1)
        #expect(broker.activeHostIDForTesting == detailHost)
    }

    @Test("空批次在进入 Translation framework 前直接失败")
    func rejectsEmptyBatchesBeforeCreatingSession() async {
        let broker = SystemTranslationSessionBroker()

        await #expect(throws: SystemTranslationError.emptyBatch) {
            try await broker.translateBatches(
                batches: [[]],
                sourceLanguage: .english,
                targetLanguage: .simplifiedChinese
            )
        }
    }

    @Test("连续 README 请求复用同一语言对的 Configuration")
    func retainsConfigurationBetweenSequentialRequests() {
        let broker = SystemTranslationSessionBroker()

        broker.activateSyntheticRequestForTesting(
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let firstVersion = broker.configuration?.version
        broker.finishActiveForTesting()

        // 请求完成不能销毁 Configuration，否则下一次请求会走旧 task 销毁 + 新 task 创建。
        #expect(broker.configuration != nil)

        broker.activateSyntheticRequestForTesting(
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        #expect(broker.configuration?.version != firstVersion)
    }

    @Test("同一语言对第三次请求必须继续递增 Configuration.version")
    func thirdSequentialSameLanguagePairBumpsConfigurationVersion() {
        let broker = SystemTranslationSessionBroker()

        broker.activateSyntheticRequestForTesting(
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let firstVersion = broker.configuration?.version
        broker.finishActiveForTesting()

        broker.activateSyntheticRequestForTesting(
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let secondVersion = broker.configuration?.version
        broker.finishActiveForTesting()

        broker.activateSyntheticRequestForTesting(
            sourceLanguage: .english,
            targetLanguage: .simplifiedChinese
        )
        let thirdVersion = broker.configuration?.version

        // SwiftUI `.translationTask` 用 Configuration == 判断是否重跑。
        // 每次 new + 一次 invalidate() 只会得到 version=1，第三次会和第二次相等，
        // 系统翻译就会停在 60 秒超时。必须 mutate 同一实例让 version 继续递增。
        #expect(firstVersion != secondVersion)
        #expect(secondVersion != thirdVersion)
        #expect(firstVersion != thirdVersion)
    }
}
