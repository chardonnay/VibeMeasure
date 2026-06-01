import SwiftUI
import UserNotifications

@main
struct VibeMeasureApp: App {
    @AppStorage("displayMode") private var displayMode = DisplayMode.providerCycles.rawValue
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some Scene {
        MenuBarExtra("VibeMeasure", systemImage: "chart.bar.xaxis") {
            UsagePopover(
                displayMode: Binding(
                    get: { DisplayMode(rawValue: displayMode) ?? .providerCycles },
                    set: { displayMode = $0.rawValue }
                ),
                launchAtLogin: $launchAtLogin
            )
            .frame(width: 460, height: 620)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(displayMode: $displayMode, launchAtLogin: $launchAtLogin)
        }
    }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case providerCycles = "Provider cycles"
    case fiveHours = "5 hours"
    case oneWeek = "1 week"
    case oneMonth = "1 month"

    var id: String { rawValue }
}

struct UsagePopover: View {
    @Binding var displayMode: DisplayMode
    @Binding var launchAtLogin: Bool

    private let sampleProviders = ProviderPreview.samples

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Display mode", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .bottom], 14)

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(sampleProviders) { provider in
                        ProviderSection(provider: provider)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.fill")
                .font(.title2)
            Text("Usage Monitor")
                .font(.headline)
            Spacer()
            Text("Manual data")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {} label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {} label: {
                Label("Reports", systemImage: "doc.text.magnifyingglass")
            }

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }

            Spacer()

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.switch)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(12)
        .background(.bar)
    }
}

struct ProviderSection: View {
    let provider: ProviderPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: provider.symbol)
                Text(provider.name)
                    .font(.headline)
                Spacer()
                Text(provider.status)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(provider.statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(provider.statusColor.opacity(0.12), in: Capsule())
            }

            ForEach(provider.windows) { window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(window.name)
                        Spacer()
                        Text(window.percentText)
                            .foregroundStyle(.green)
                            .fontWeight(.bold)
                    }
                    ProgressView(value: window.percent)
                        .tint(.green)
                    Text(window.resetText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SettingsView: View {
    @Binding var displayMode: String
    @Binding var launchAtLogin: Bool

    var body: some View {
        Form {
            Picker("Default display mode", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode.rawValue)
                }
            }
            Toggle("Launch at Login", isOn: $launchAtLogin)
            Text("Provider limits and pricing remain manual until verified by a local adapter or official API integration.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 560)
        .frame(minHeight: 320)
    }
}

struct ProviderPreview: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let status: String
    let statusColor: Color
    let windows: [WindowPreview]

    static let samples = [
        ProviderPreview(
            id: "claude",
            name: "Claude Code",
            symbol: "sparkle",
            status: "Manual",
            statusColor: .orange,
            windows: [
                WindowPreview(name: "5-Hour", percent: 0.04, resetText: "Configure limits to verify reset time"),
                WindowPreview(name: "7-Day", percent: 0.21, resetText: "Manual or verified API data required")
            ]
        ),
        ProviderPreview(
            id: "codex",
            name: "Codex CLI",
            symbol: "swirl.circle.righthalf.filled",
            status: "Local",
            statusColor: .green,
            windows: [
                WindowPreview(name: "5-Hour", percent: 0.01, resetText: "Read from local token_count events")
            ]
        ),
        ProviderPreview(
            id: "more",
            name: "More providers",
            symbol: "ellipsis.circle",
            status: "Setup",
            statusColor: .secondary,
            windows: [
                WindowPreview(name: "Manual setup required", percent: 0, resetText: "No limits are guessed")
            ]
        )
    ]
}

struct WindowPreview: Identifiable {
    let id = UUID()
    let name: String
    let percent: Double
    let resetText: String

    var percentText: String {
        "\(Int(percent * 100))%"
    }
}
