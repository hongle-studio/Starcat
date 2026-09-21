//
//  LocalAIOperationGate.swift
//  Starcat
//
//  GPU 工作的 FIFO 准入门。actor 在 await 处可重入，不能单靠 actor 隔离推理全过程。
//  不阻塞线程；取消排队请求时移除 continuation，避免卸载后旧请求又加载模型。
//

import Foundation

/// 用异步许可覆盖整个 GPU 作业，不依赖 actor 方法在 await 期间保持排他。
actor LocalAIOperationGate {
    private var occupied = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// 成功获取的调用者必须 release，且应覆盖加载、推理、GPU 收尾的完整生命周期。
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if occupied {
                    waiters.append((id, continuation))
                } else {
                    occupied = true
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
