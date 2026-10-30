//
//  AppStoreToDirectImportController.swift
//  Starcat
//
//  Direct 首次导入的启动期门面：判断要不要问、执行拷贝、记下选择。
//
//  启动链要求：splash 期间不要 restore 登录；用户点完按钮之后再 restore。
//  查 Swift 学习索引：`@Observable`、`Task` 与 MainActor。
//

import Foundation
import Observation

@MainActor
@Observable
final class AppStoreToDirectImportController {
    private(set) var isCopying = false
    private(set) var errorMessage: String?

    private let layout: AppStoreToDirectImportLayout
    private let fileManager: FileManager
    private let decisionStore: AppStoreToDirectImportDecisionStore
    private let processInspector: any AppStoreToDirectImportProcessInspecting
    private let destinationDefaults: UserDefaults
    private let bundleIdentifier: String?
    private let channel: DistributionChannel

    init(
        layout: AppStoreToDirectImportLayout = .live(),
        fileManager: FileManager = .default,
        decisionStore: AppStoreToDirectImportDecisionStore = AppStoreToDirectImportDecisionStore(),
        processInspector: any AppStoreToDirectImportProcessInspecting = LaunchServicesAppStoreProcessInspector(),
        destinationDefaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        channel: DistributionChannel = .current
    ) {
        self.layout = layout
        self.fileManager = fileManager
        self.decisionStore = decisionStore
        self.processInspector = processInspector
        self.destinationDefaults = destinationDefaults
        self.bundleIdentifier = bundleIdentifier
        self.channel = channel
    }

    /// 是否应在 splash 之后弹出确认层。测试 host 永远跳过。
    func shouldPromptOnLaunch() -> Bool {
        guard !TestEnvironment.isRunning else { return false }
        let isEligible = AppStoreToDirectImportEvaluator.isEligibleDirectBuild(
            bundleIdentifier: bundleIdentifier,
            channel: channel
        )
        let hasRecordedDecision = decisionStore.decision != nil
        let storeHasImportableData = AppStoreToDirectImportEvaluator.storeHasImportableData(
            layout: layout,
            fileManager: fileManager
        )
        let destinationIsEmpty = AppStoreToDirectImportEvaluator.destinationIsEmpty(
            layout: layout,
            fileManager: fileManager
        )
        let shouldPrompt = AppStoreToDirectImportEvaluator.shouldPrompt(
            isEligibleDirectBuild: isEligible,
            hasRecordedDecision: hasRecordedDecision,
            storeHasImportableData: storeHasImportableData,
            destinationIsEmpty: destinationIsEmpty
        )
        AppLog.general.info(
            "Direct import prompt eligible=\(isEligible, privacy: .public) decision=\(hasRecordedDecision, privacy: .public) store=\(storeHasImportableData, privacy: .public) empty=\(destinationIsEmpty, privacy: .public) show=\(shouldPrompt, privacy: .public) bundle=\(self.bundleIdentifier ?? "nil", privacy: .public) channel=\(self.channel.rawValue, privacy: .public)"
        )
        return shouldPrompt
    }

    func skipImport() {
        decisionStore.record(.skipped)
        errorMessage = nil
        AppLog.general.info("Direct first-launch import skipped by user")
    }

    func copyImport() async -> Bool {
        isCopying = true
        errorMessage = nil
        defer { isCopying = false }

        if processInspector.isAppStoreStarcatRunning() {
            errorMessage = AppStoreToDirectImportError.storeAppRunning.localizedDescription
            return false
        }

        let layout = self.layout
        do {
            try await Task.detached(priority: .userInitiated) {
                try AppStoreToDirectImportCopyService.copyStagedFiles(layout: layout)
            }.value
            AppStoreToDirectImportCopyService(
                layout: layout,
                fileManager: fileManager,
                processInspector: processInspector,
                destinationDefaults: destinationDefaults
            ).migratePreferencesForCurrentLayout()
            decisionStore.record(.imported)
            AppLog.general.info("Direct first-launch import copied App Store data")
            return true
        } catch {
            errorMessage = error.localizedDescription
            AppLog.general.error("Direct first-launch import failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
