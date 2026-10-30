//
//  LocalAILogWindowSelection.swift
//  Starcat
//
//  单例日志 Scene 的打开意图。不持有 NSWindow，也不创建或加载本地模型。
//

import Observation

/// 每次点击模型菜单均递增版本，即使模型没变也能重新唤起并定位日志尾部。
@MainActor @Observable
final class LocalAILogWindowSelection {
    static let shared = LocalAILogWindowSelection()
    static let sceneID = "local-ai-logs"
    private(set) var modelID: String?
    private(set) var revision = 0

    func select(_ modelID: String) {
        self.modelID = modelID
        revision += 1
    }
}
