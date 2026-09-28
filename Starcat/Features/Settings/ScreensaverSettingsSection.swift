//
//  ScreensaverSettingsSection.swift
//  Starcat
//
//  Direct「macOS 集成」里的屏保安装 / 更新 / 移除。App Store 构建不编译进可见 UI。
//  安装只拷 .saver；头像快照由 App 启动 / Stars 同步发布，重装不得重下。
//

import AppKit
import SwiftUI

/// Direct 设置页的屏保安装控制。按钮右对齐，符合设置页一次性操作规范。
struct ScreensaverSettingsSection: View {
    @Environment(AppDependencies.self) private var dependencies

    @State private var status: ScreensaverInstallStatus = .notInstalled
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress = dependencies.screensaverRefreshCoordinator.avatarProgress,
               progress.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(
                        value: Double(progress.completed),
                        total: Double(progress.total)
                    )
                    Text(
                        String(
                            format: String.l10n("settings.general.screensaver.progressFmt"),
                            progress.completed,
                            progress.total
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }

            HStack {
                Spacer()
                if showsInstallButton {
                    Button(installButtonTitle, action: installOrUpdate)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isBusy || installer == nil)
                }
                if showsSystemOpenButton {
                    Button("settings.general.screensaver.openSystemInstaller", action: openWithSystemInstaller)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isBusy || installer == nil)
                }
                if showsRemoveButton {
                    Button("settings.general.screensaver.remove", action: remove)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isBusy)
                }
            }
        }
        .onAppear(perform: refreshStatus)
    }

    private var installer: ScreensaverInstaller? {
        ScreensaverInstaller.makeProduction()
    }

    private var showsInstallButton: Bool {
        switch status {
        case .notInstalled, .updateAvailable:
            return true
        case .installed:
            return false
        }
    }

    private var showsRemoveButton: Bool {
        if case .notInstalled = status { return false }
        return true
    }

    private var showsSystemOpenButton: Bool {
        if case .notInstalled = status { return false }
        return true
    }

    private var installButtonTitle: LocalizedStringKey {
        switch status {
        case .updateAvailable:
            return "settings.general.screensaver.update"
        default:
            return "settings.general.screensaver.install"
        }
    }

    private var statusText: LocalizedStringKey {
        switch status {
        case .notInstalled:
            return "settings.general.screensaver.status.notInstalled"
        case .installed:
            return "settings.general.screensaver.status.installed"
        case .updateAvailable:
            return "settings.general.screensaver.status.needsUpdate"
        }
    }

    private func refreshStatus() {
        status = installer?.status() ?? .notInstalled
    }

    private func installOrUpdate() {
        guard let installer else {
            errorMessage = String.l10n("settings.general.screensaver.error.install")
            return
        }
        isBusy = true
        errorMessage = nil
        do {
            try installer.install()
            refreshStatus()
            openWithSystemInstaller()
        } catch {
            errorMessage = String.l10n("settings.general.screensaver.error.install")
        }
        isBusy = false
    }

    private func openWithSystemInstaller() {
        guard let installer else { return }
        _ = installer.openWithSystemInstaller { url in
            NSWorkspace.shared.open(url)
        }
    }

    private func remove() {
        guard let installer else { return }
        isBusy = true
        errorMessage = nil
        do {
            try installer.uninstall()
            refreshStatus()
        } catch {
            errorMessage = String.l10n("settings.general.screensaver.error.remove")
        }
        isBusy = false
    }
}
