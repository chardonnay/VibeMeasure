import AppKit
import ServiceManagement
import SwiftUI

struct LaunchAtLoginSetting: View {
    @State private var status: SMAppService.Status = .notRegistered
    @State private var errorMessage: String?

    private let isPackaged = Bundle.main.bundleURL.pathExtension == "app"
        && Bundle.main.bundleIdentifier != nil

    var body: some View {
        Toggle("Launch at Login", isOn: Binding(
            get: { status == .enabled },
            set: setEnabled
        ))
        .disabled(!isPackaged || status == .notFound)
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }

        if !isPackaged {
            Text("Launch at Login is available in the packaged VibeMeasure app.")
                .font(.caption).foregroundStyle(.secondary)
        } else if status == .requiresApproval {
            Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        } else if status == .notFound {
            Text("macOS could not find the VibeMeasure login item.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(.red)
        }
    }

    private func refreshStatus() {
        if isPackaged {
            status = SMAppService.mainApp.status
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard isPackaged else { return }
        errorMessage = nil
        let service = SMAppService.mainApp
        do {
            if enabled && service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if enabled && service.status != .enabled {
                try service.register()
            } else if !enabled && service.status == .enabled {
                try service.unregister()
            }
        } catch {
            errorMessage = "Could not change Launch at Login. \(error.localizedDescription)"
        }
        refreshStatus()
    }
}
