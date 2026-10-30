//
//  ScreensaverInstaller.swift
//  Starcat
//
//  把 Direct App 内嵌的 Starcat.saver 复制到用户 Screen Savers 目录。
//
//  关键约束：
//  - 只覆盖目标 `Starcat.saver`，不改 App 包内已签名 bundle；
//  - 先拷到同目录临时名再 replace，避免半个 bundle；
//  - 移除只删这一份 .saver，不碰 App Group 快照。
//

import Foundation

/// 本机已安装屏保与 App 内嵌 bundle 的关系。
enum ScreensaverInstallStatus: Equatable, Sendable {
    case notInstalled
    case installed(version: String, build: String)
    case updateAvailable(
        installedVersion: String,
        installedBuild: String,
        bundledVersion: String,
        bundledBuild: String
    )
}

/// 安装或移除失败的稳定分类。
enum ScreensaverInstallerError: Error, Equatable, LocalizedError {
    case bundledSaverMissing
    case copyFailed
    case removeFailed

    var errorDescription: String? {
        switch self {
        case .bundledSaverMissing:
            return "Bundled Starcat screensaver is missing"
        case .copyFailed:
            return "Starcat screensaver could not be installed"
        case .removeFailed:
            return "Starcat screensaver could not be removed"
        }
    }
}

/// Direct 设置页使用的屏保安装器。
struct ScreensaverInstaller: Sendable {
    static let installedFileName = "Starcat.saver"

    private let bundledSaverURL: URL
    private let destinationDirectoryURL: URL

    var destinationURL: URL {
        destinationDirectoryURL.appendingPathComponent(Self.installedFileName, isDirectory: true)
    }

    init(
        bundledSaverURL: URL,
        destinationDirectoryURL: URL = ScreensaverInstaller.defaultDestinationDirectory()
    ) {
        self.bundledSaverURL = bundledSaverURL
        self.destinationDirectoryURL = destinationDirectoryURL
    }

    /// 生产入口：从 Direct App 包内 `Contents/Library/Screen Savers/Starcat.saver` 安装。
    static func makeProduction() -> ScreensaverInstaller? {
        guard let bundledURL = bundledSaverURLInMainBundle() else { return nil }
        return ScreensaverInstaller(bundledSaverURL: bundledURL)
    }

    static func bundledSaverURLInMainBundle(bundle: Bundle = .main) -> URL? {
        let fileNames = [installedFileName, "StarcatScreensaver.saver"]
        let directories = [
            bundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Screen Savers", isDirectory: true),
            bundle.builtInPlugInsURL,
            bundle.resourceURL
        ].compactMap { $0 }
        for directory in directories {
            for fileName in fileNames {
                let url = directory.appendingPathComponent(fileName, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    static func defaultDestinationDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Screen Savers", isDirectory: true)
    }

    func status() -> ScreensaverInstallStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            return .notInstalled
        }
        let installed = versionPair(at: destinationURL)
        let bundled = versionPair(at: bundledSaverURL)
        if fileManager.fileExists(atPath: bundledSaverURL.path),
           installed != bundled {
            return .updateAvailable(
                installedVersion: installed.version,
                installedBuild: installed.build,
                bundledVersion: bundled.version,
                bundledBuild: bundled.build
            )
        }
        return .installed(version: installed.version, build: installed.build)
    }

    func install() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundledSaverURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScreensaverInstallerError.bundledSaverMissing
        }

        do {
            try fileManager.createDirectory(
                at: destinationDirectoryURL,
                withIntermediateDirectories: true
            )
            let temporaryURL = destinationDirectoryURL.appendingPathComponent(
                ".\(Self.installedFileName).\(UUID().uuidString).tmp",
                isDirectory: true
            )
            try fileManager.copyItem(at: bundledSaverURL, to: temporaryURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch let error as ScreensaverInstallerError {
            throw error
        } catch {
            throw ScreensaverInstallerError.copyFailed
        }
    }

    /// 先把 `.saver` 拷到系统目录，快照发布放到后台。
    ///
    /// 关键约束：Owner 可能有上千个，头像下载不能挡住安装；否则系统设置里一直看不到 Starcat。
    func installThenPublishInBackground(_ publish: @escaping @MainActor () async -> Void) throws {
        try install()
        Task { @MainActor in
            await publish()
        }
    }

    /// 用系统方式打开已拷贝的 `.saver`。
    ///
    /// Apple / 第三方屏保的正规入口是双击 bundle：系统设置会弹出「为当前用户安装」。
    /// 只把文件放到 `~/Library/Screen Savers/` 在 Tahoe 上经常不会出现在「自定 → 其他」。
    @discardableResult
    func openWithSystemInstaller(open: (URL) -> Bool) -> Bool {
        open(destinationURL)
    }

    func uninstall() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destinationURL.path) else { return }
        do {
            try fileManager.removeItem(at: destinationURL)
        } catch {
            throw ScreensaverInstallerError.removeFailed
        }
    }

    private func versionPair(at bundleURL: URL) -> (version: String, build: String) {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        let info = NSDictionary(contentsOf: infoURL) as? [String: Any]
        let version = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (version?.isEmpty == false ? version! : "0", build?.isEmpty == false ? build! : "0")
    }
}
