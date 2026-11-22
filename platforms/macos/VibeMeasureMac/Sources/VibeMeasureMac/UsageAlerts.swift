import Foundation
import SwiftUI
import UserNotifications

struct ProviderAlertRule: Codable, Equatable {
    var expiryEnabled = false
    var endDay: DateComponents?
    var daysBefore = 7
    var usageEnabled = false
    var usedPercent = 90

    func evaluate(name: String, windows: [WindowPreview], now: Date,
                  receipts: inout [String: String]) -> [String] {
        var messages: [String] = []
        let calendar = Calendar.autoupdatingCurrent
        if expiryEnabled, let endDay, let date = calendar.date(from: endDay),
           let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                              to: calendar.startOfDay(for: date)).day,
           (0...daysBefore).contains(days) {
            let cycle = "\(endDay.year ?? 0)-\(endDay.month ?? 0)-\(endDay.day ?? 0)"
            if receipts["end"] != cycle {
                messages.append("\(name) subscription ends \(date.formatted(date: .abbreviated, time: .omitted)) (\(days) days remaining).")
                receipts["end"] = cycle
            }
        }
        guard usageEnabled else { return messages }
        for window in windows where window.hasKnownPercent && (window.resetsAt.map { $0 > now } ?? true) {
            let key = "quota/" + window.quotaKey
            let cycle = "\(usedPercent)/" + (window.resetsAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "")
            if window.percent + 1e-12 < Double(usedPercent) / 100 {
                if window.resetsAt == nil { receipts.removeValue(forKey: key) }
            } else if receipts[key] != cycle {
                messages.append("\(name) · \(window.name): \((100 * window.percent).formatted())% used (threshold \(usedPercent)%).")
                receipts[key] = cycle
            }
        }
        return messages
    }
}

final class ForegroundAlertPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
enum UsageAlerts {
    static func check(providers: [ProviderSettings], readings: [String: ProviderLiveUsage]) async {
        for provider in providers where provider.alerts.usageEnabled || provider.alerts.expiryEnabled {
            let key = "alert.receipts." + provider.id
            let previous = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            var receipts = previous
            let windows = provider.dataSource == .manual
                ? provider.visibleManualWindows.map(WindowPreview.init(window:))
                : readings[provider.id]?.windows ?? []
            let messages = provider.alerts.evaluate(name: provider.displayName, windows: windows,
                                                    now: Date(), receipts: &receipts)
            if !messages.isEmpty {
                do { try await deliver(messages.joined(separator: "\n")) }
                catch { continue } // Retry on the next refresh after permission or delivery failures.
            }
            if previous != receipts { UserDefaults.standard.set(receipts, forKey: key) }
        }
    }

    static func authorize() async throws -> Bool {
        if Bundle.main.bundleURL.pathExtension != "app" { return true }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private static func deliver(_ message: String) async throws {
        if Bundle.main.bundleURL.pathExtension != "app" {
            // SwiftPM executables lack the bundle identity required by UserNotifications.
            let result = try await Task.detached {
                try LocalAgentCommand.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                    arguments: ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"VibeMeasure\"",
                                "-e", "end run", "--", message])
            }.value
            guard result.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
            return
        }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else {
            throw CocoaError(.userCancelled)
        }
        let content = UNMutableNotificationContent()
        content.title = "VibeMeasure"
        content.body = message
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

struct AlertRuleEditor: View {
    @Binding var rule: ProviderAlertRule
    @State private var draft = ProviderAlertRule()
    @State private var feedback = ""

    var body: some View {
        Section("Notifications") {
            Toggle("Remind me before my subscription ends", isOn: $draft.expiryEnabled)
            if draft.expiryEnabled {
                DatePicker("Subscription end", selection: Binding(
                    get: { draft.endDay.flatMap { Calendar.current.date(from: $0) } ?? Date() },
                    set: { draft.endDay = Calendar.current.dateComponents([.year, .month, .day], from: $0) }
                ), displayedComponents: .date)
                Stepper("Days before end: \(draft.daysBefore)", value: $draft.daysBefore, in: 0...365)
            }
            Toggle("Warn me about quota usage", isOn: $draft.usageEnabled)
            if draft.usageEnabled {
                Stepper("Usage threshold: \(draft.usedPercent)%", value: $draft.usedPercent, in: 1...100)
            }
            Button("Save notification settings") {
                if draft.expiryEnabled && draft.endDay == nil {
                    draft.endDay = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                }
                rule = draft
                feedback = "Settings saved."
                if draft.expiryEnabled || draft.usageEnabled {
                    Task {
                        if (try? await UsageAlerts.authorize()) != true {
                            feedback = "Settings saved. Allow VibeMeasure notifications in System Settings."
                        }
                    }
                }
            }
            if !feedback.isEmpty { Text(feedback).font(.caption) }
        }
        .onAppear { draft = rule }
    }
}
