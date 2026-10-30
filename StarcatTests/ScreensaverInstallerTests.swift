//
//  ScreensaverInstallerTests.swift
//  StarcatTests
//
//  Direct 屏保安装器只操作注入的源 bundle 和目标目录，不碰本机真实 Screen Savers。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ScreensaverInstaller")
struct ScreensaverInstallerTests {

    @Test("目标不存在时状态为未安装")
    func reportsNotInstalledWhenDestinationMissing() throws {
        try withTemporaryDirectory { directory in
            let installer = ScreensaverInstaller(
                bundledSaverURL: directory.appendingPathComponent("Starcat.saver"),
                destinationDirectoryURL: directory.appendingPathComponent("Screen Savers")
            )
            #expect(installer.status() == .notInstalled)
        }
    }

    @Test("安装会覆盖复制 bundle，并在版本一致时报告已安装")
    func installCopiesBundleAndReportsInstalled() throws {
        try withTemporaryDirectory { directory in
            let source = try makeSaverBundle(in: directory, name: "Source.saver", version: "1.7.0", build: "100")
            let destinationDirectory = directory.appendingPathComponent("Screen Savers")
            let installer = ScreensaverInstaller(
                bundledSaverURL: source,
                destinationDirectoryURL: destinationDirectory
            )

            try installer.install()

            #expect(installer.status() == .installed(version: "1.7.0", build: "100"))
            #expect(
                FileManager.default.fileExists(
                    atPath: destinationDirectory.appendingPathComponent("Starcat.saver").path
                )
            )
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test("内嵌版本更高时报告可更新，覆盖安装后恢复已安装")
    func reportsUpdateThenInstallsNewerBundle() throws {
        try withTemporaryDirectory { directory in
            let destinationDirectory = directory.appendingPathComponent("Screen Savers")
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            _ = try makeSaverBundle(
                in: destinationDirectory,
                name: "Starcat.saver",
                version: "1.6.0",
                build: "90"
            )
            let source = try makeSaverBundle(in: directory, name: "Source.saver", version: "1.7.0", build: "100")
            let installer = ScreensaverInstaller(
                bundledSaverURL: source,
                destinationDirectoryURL: destinationDirectory
            )

            #expect(
                installer.status() == .updateAvailable(
                    installedVersion: "1.6.0",
                    installedBuild: "90",
                    bundledVersion: "1.7.0",
                    bundledBuild: "100"
                )
            )

            try installer.install()
            #expect(installer.status() == .installed(version: "1.7.0", build: "100"))
        }
    }

    @Test("移除只删除已安装的 .saver，源 bundle 保持不变")
    func uninstallRemovesInstalledSaverOnly() throws {
        try withTemporaryDirectory { directory in
            let source = try makeSaverBundle(in: directory, name: "Source.saver", version: "1.7.0", build: "100")
            let destinationDirectory = directory.appendingPathComponent("Screen Savers")
            let sibling = destinationDirectory.appendingPathComponent("Other.saver")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            let installer = ScreensaverInstaller(
                bundledSaverURL: source,
                destinationDirectoryURL: destinationDirectory
            )
            try installer.install()
            try installer.uninstall()

            #expect(installer.status() == .notInstalled)
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(FileManager.default.fileExists(atPath: sibling.path))
        }
    }

    @Test("源 bundle 缺失时安装失败且不创建目标")
    func installFailsWhenBundledSaverMissing() throws {
        try withTemporaryDirectory { directory in
            let destinationDirectory = directory.appendingPathComponent("Screen Savers")
            let installer = ScreensaverInstaller(
                bundledSaverURL: directory.appendingPathComponent("Missing.saver"),
                destinationDirectoryURL: destinationDirectory
            )

            #expect(throws: ScreensaverInstallerError.bundledSaverMissing) {
                try installer.install()
            }
            #expect(FileManager.default.fileExists(atPath: destinationDirectory.path) == false)
        }
    }

    @Test("安装先复制 bundle，不等待后台快照发布结束")
    func installCopiesBeforeBackgroundPublishFinishes() async throws {
        try await withTemporaryDirectory { directory in
            let source = try makeSaverBundle(in: directory, name: "Source.saver", version: "1.7.0", build: "100")
            let destinationDirectory = directory.appendingPathComponent("Screen Savers")
            let installer = ScreensaverInstaller(
                bundledSaverURL: source,
                destinationDirectoryURL: destinationDirectory
            )
            let gate = PublishGate()

            try installer.installThenPublishInBackground {
                await gate.waitUntilReleased()
            }

            #expect(
                FileManager.default.fileExists(
                    atPath: destinationDirectory.appendingPathComponent("Starcat.saver").path
                )
            )
            #expect(installer.status() == .installed(version: "1.7.0", build: "100"))
            await gate.release()
        }
    }

    @Test("系统安装入口打开的是已拷贝的 Starcat.saver")
    func openWithSystemInstallerUsesDestinationURL() throws {
        try withTemporaryDirectory { directory in
            let source = try makeSaverBundle(in: directory, name: "Source.saver", version: "1.7.0", build: "100")
            let destinationDirectory = directory.appendingPathComponent("Screen Savers")
            let installer = ScreensaverInstaller(
                bundledSaverURL: source,
                destinationDirectoryURL: destinationDirectory
            )
            try installer.install()

            var opened: URL?
            let didOpen = installer.openWithSystemInstaller { url in
                opened = url
                return true
            }

            #expect(didOpen)
            #expect(opened == installer.destinationURL)
            #expect(opened?.lastPathComponent == "Starcat.saver")
        }
    }

    private func makeSaverBundle(
        in directory: URL,
        name: String,
        version: String,
        build: String
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundleURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-screensaver-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-screensaver-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// 卡住后台发布，用来证明复制已经先完成。
    private actor PublishGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func waitUntilReleased() async {
            if released { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}
