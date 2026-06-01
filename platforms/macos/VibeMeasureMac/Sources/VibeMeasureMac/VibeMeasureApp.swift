import Combine
import SwiftUI
import UserNotifications

@main
struct VibeMeasureApp: App {
    @AppStorage("displayMode") private var displayMode = DisplayMode.providerCycles.rawValue
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @StateObject private var providerStore = ProviderSettingsStore()

    var body: some Scene {
        MenuBarExtra("VibeMeasure", systemImage: "chart.bar.xaxis") {
            UsagePopover(
                displayMode: Binding(
                    get: { DisplayMode(rawValue: displayMode) ?? .providerCycles },
                    set: { displayMode = $0.rawValue }
                ),
                launchAtLogin: $launchAtLogin,
                providerStore: providerStore
            )
            .frame(width: 460, height: 620)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                displayMode: $displayMode,
                launchAtLogin: $launchAtLogin,
                providerStore: providerStore
            )
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
    @ObservedObject var providerStore: ProviderSettingsStore

    private var providers: [ProviderPreview] {
        providerStore.providers
            .filter(\.isEnabled)
            .map(ProviderPreview.init(settings:))
    }

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
                    if providers.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "gearshape")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No enabled providers")
                                .font(.headline)
                            Text("Open Settings to enable or add providers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            SettingsLink {
                                Text("Open Settings")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    }

                    ForEach(providers) { provider in
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

            Toggle(isOn: $launchAtLogin) {
                Image(systemName: "poweron")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help("Launch at Login")

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
    @ObservedObject var providerStore: ProviderSettingsStore
    @State private var selectedProviderID: String?

    private var selectedProviderBinding: Binding<ProviderSettings>? {
        guard let selectedProviderID else {
            return nil
        }

        return providerStore.binding(for: selectedProviderID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Default display mode", selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                Toggle("Launch at Login", isOn: $launchAtLogin)
            }
            .padding()

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    List(selection: $selectedProviderID) {
                        ForEach(providerStore.providers) { provider in
                            ProviderListRow(provider: provider)
                                .tag(provider.id)
                        }
                    }

                    HStack {
                        Button {
                            let provider = providerStore.addProvider()
                            selectedProviderID = provider.id
                        } label: {
                            Label("Add Provider", systemImage: "plus")
                        }

                        Spacer()

                        if let selectedProviderID,
                           providerStore.canDeleteProvider(id: selectedProviderID) {
                            Button(role: .destructive) {
                                providerStore.deleteProvider(id: selectedProviderID)
                                self.selectedProviderID = providerStore.providers.first?.id
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .controlSize(.small)
                    .padding([.horizontal, .bottom], 10)
                }
                .frame(width: 240)

                Divider()

                Group {
                    if let selectedProviderBinding {
                        ProviderEditor(provider: selectedProviderBinding)
                    } else {
                        ContentUnavailableView(
                            "Select a provider",
                            systemImage: "list.bullet.rectangle",
                            description: Text("Choose a provider to edit its name, command, data source, and manual windows.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text("Provider limits, prices, model names, and reset windows stay manual or unknown until verified by a local adapter, official API, official documentation, or your own entry.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
        .frame(width: 860)
        .frame(minHeight: 640)
        .onAppear {
            selectedProviderID = selectedProviderID ?? providerStore.providers.first?.id
        }
    }
}

struct ProviderPreview: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let status: String
    let statusColor: Color
    let windows: [WindowPreview]

    init(settings: ProviderSettings) {
        id = settings.id
        name = settings.displayName
        symbol = settings.symbolName
        status = settings.dataSource.shortLabel
        statusColor = settings.dataSource.color
        windows = settings.manualWindows.isEmpty
            ? [WindowPreview(name: "Manual setup required", percent: 0, resetText: "No limits are guessed")]
            : settings.manualWindows.map(WindowPreview.init(window:))
    }
}

struct WindowPreview: Identifiable {
    let id = UUID()
    let name: String
    let percent: Double
    let resetText: String

    var percentText: String {
        "\(Int(percent * 100))%"
    }

    init(name: String, percent: Double, resetText: String) {
        self.name = name
        self.percent = percent
        self.resetText = resetText
    }

    init(window: ManualUsageWindow) {
        name = window.label.isEmpty ? window.kind.rawValue : window.label
        percent = min(max(window.usedPercent / 100, 0), 1)
        resetText = window.resetNote.isEmpty ? "Manual window" : window.resetNote
    }
}

struct ProviderListRow: View {
    let provider: ProviderSettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: provider.symbolName)
                .foregroundStyle(provider.isEnabled ? provider.dataSource.color : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .lineLimit(1)
                Text(provider.id)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !provider.isEnabled {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProviderEditor: View {
    @Binding var provider: ProviderSettings

    var body: some View {
        Form {
            Section("Provider") {
                LabeledContent("Tool ID") {
                    Text(provider.id)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                TextField("Display name", text: $provider.displayName)
                TextField("Command hint", text: $provider.commandHint)
                TextField("SF Symbol", text: $provider.symbolName)
                Picker("Data source", selection: $provider.dataSource) {
                    ForEach(ProviderDataSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                Toggle("Enabled in popover and widget", isOn: $provider.isEnabled)
            }

            Section("Manual windows") {
                if provider.manualWindows.isEmpty {
                    Text("No manual windows configured.")
                        .foregroundStyle(.secondary)
                }

                ForEach($provider.manualWindows) { $window in
                    ManualWindowEditor(window: $window) {
                        provider.manualWindows.removeAll { $0.id == window.id }
                    }
                }

                Button {
                    provider.manualWindows.append(ManualUsageWindow())
                } label: {
                    Label("Add Window", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ManualWindowEditor: View {
    @Binding var window: ManualUsageWindow
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Kind", selection: $window.kind) {
                    ForEach(UsageWindowKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }

                Spacer()

                Button(role: .destructive, action: delete) {
                    Label("Remove", systemImage: "minus.circle")
                }
                .labelStyle(.iconOnly)
            }

            TextField("Label", text: $window.label)
            HStack {
                Slider(value: $window.usedPercent, in: 0...100, step: 1)
                Text("\(Int(window.usedPercent))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            TextField("Reset note", text: $window.resetNote)
            TextField("Token limit", text: $window.tokenLimit)
            TextField("Cost note", text: $window.costNote)
        }
        .padding(.vertical, 6)
    }
}

@MainActor
final class ProviderSettingsStore: ObservableObject {
    @Published private(set) var providers: [ProviderSettings] = [] {
        didSet {
            save()
        }
    }

    private let storageKey = "providerSettings.v1"
    private let storageVersionKey = "providerSettings.version"
    private static let currentStorageVersion = 2

    init() {
        var loadedProviders = loadProviders()
        if UserDefaults.standard.integer(forKey: storageVersionKey) < Self.currentStorageVersion {
            loadedProviders = loadedProviders.map { provider in
                var migratedProvider = provider
                migratedProvider.isEnabled = false
                return migratedProvider
            }
            save(loadedProviders)
            UserDefaults.standard.set(Self.currentStorageVersion, forKey: storageVersionKey)
        }
        providers = loadedProviders
    }

    func binding(for id: String) -> Binding<ProviderSettings>? {
        guard providers.contains(where: { $0.id == id }) else {
            return nil
        }

        return Binding(
            get: { self.providers.first(where: { $0.id == id }) ?? ProviderSettings.customTemplate(id: id) },
            set: { self.updateProvider($0) }
        )
    }

    func addProvider() -> ProviderSettings {
        let provider = ProviderSettings.customTemplate(id: nextCustomID())
        providers.append(provider)
        return provider
    }

    func canDeleteProvider(id: String) -> Bool {
        providers.first(where: { $0.id == id })?.isBuiltIn == false
    }

    func deleteProvider(id: String) {
        guard canDeleteProvider(id: id) else {
            return
        }
        providers.removeAll { $0.id == id }
    }

    private func updateProvider(_ provider: ProviderSettings) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else {
            return
        }
        providers[index] = provider
    }

    private func loadProviders() -> [ProviderSettings] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ProviderSettings].self, from: data) else {
            return Self.defaultProviders
        }

        var merged = decoded
        for provider in Self.defaultProviders where !merged.contains(where: { $0.id == provider.id }) {
            merged.append(provider)
        }
        return merged
    }

    private func save() {
        save(providers)
    }

    private func save(_ providers: [ProviderSettings]) {
        guard let data = try? JSONEncoder().encode(providers) else {
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func nextCustomID() -> String {
        let base = "custom-provider"
        if !providers.contains(where: { $0.id == base }) {
            return base
        }

        var suffix = 2
        while providers.contains(where: { $0.id == "\(base)-\(suffix)" }) {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private static let defaultProviders: [ProviderSettings] = [
        .builtIn(id: "claude", displayName: "Claude Code", commandHint: "claude", symbolName: "sparkle"),
        .builtIn(id: "codex", displayName: "Codex CLI", commandHint: "codex", symbolName: "swirl.circle.righthalf.filled", dataSource: .localAdapter),
        .builtIn(id: "devin-terminal", displayName: "Devin for Terminal", commandHint: "", symbolName: "terminal"),
        .builtIn(id: "gemini", displayName: "Gemini CLI", commandHint: "gemini", symbolName: "diamond"),
        .builtIn(id: "opencode", displayName: "OpenCode", commandHint: "opencode", symbolName: "curlybraces"),
        .builtIn(id: "hermes", displayName: "Hermes", commandHint: "", symbolName: "paperplane"),
        .builtIn(id: "kimi-cli", displayName: "Kimi CLI", commandHint: "", symbolName: "moon"),
        .builtIn(id: "cursor-agent", displayName: "Cursor Agent", commandHint: "cursor-agent", symbolName: "cursorarrow"),
        .builtIn(id: "qwen-code", displayName: "Qwen Code", commandHint: "", symbolName: "q.circle"),
        .builtIn(id: "qoder-cli", displayName: "Qoder CLI", commandHint: "", symbolName: "terminal.fill"),
        .builtIn(id: "github-copilot-cli", displayName: "GitHub Copilot CLI", commandHint: "", symbolName: "chevron.left.forwardslash.chevron.right"),
        .builtIn(id: "pi", displayName: "Pi", commandHint: "", symbolName: "p.circle"),
        .builtIn(id: "kiro-cli", displayName: "Kiro CLI", commandHint: "", symbolName: "k.circle"),
        .builtIn(id: "kilo", displayName: "Kilo", commandHint: "", symbolName: "k.square"),
        .builtIn(id: "mistral-vibe-cli", displayName: "Mistral Vibe CLI", commandHint: "", symbolName: "wind"),
        .builtIn(id: "deepseek-tui", displayName: "DeepSeek TUI", commandHint: "", symbolName: "magnifyingglass"),
        .builtIn(id: "minimax", displayName: "MiniMAX", commandHint: "", symbolName: "m.square")
    ]
}

struct ProviderSettings: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var commandHint: String
    var symbolName: String
    var dataSource: ProviderDataSource
    var isBuiltIn: Bool
    var isEnabled: Bool
    var manualWindows: [ManualUsageWindow]

    static func builtIn(
        id: String,
        displayName: String,
        commandHint: String,
        symbolName: String,
        dataSource: ProviderDataSource = .manual
    ) -> ProviderSettings {
        ProviderSettings(
            id: id,
            displayName: displayName,
            commandHint: commandHint,
            symbolName: symbolName,
            dataSource: dataSource,
            isBuiltIn: true,
            isEnabled: false,
            manualWindows: []
        )
    }

    static func customTemplate(id: String) -> ProviderSettings {
        ProviderSettings(
            id: id,
            displayName: "New Provider",
            commandHint: "",
            symbolName: "terminal",
            dataSource: .manual,
            isBuiltIn: false,
            isEnabled: false,
            manualWindows: []
        )
    }
}

struct ManualUsageWindow: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind = UsageWindowKind.fiveHours
    var label = "5-Hour"
    var usedPercent = 0.0
    var resetNote = ""
    var tokenLimit = ""
    var costNote = ""
}

enum UsageWindowKind: String, Codable, CaseIterable, Identifiable {
    case fiveHours = "5-Hour"
    case oneWeek = "1 Week"
    case oneMonth = "1 Month"
    case custom = "Custom"

    var id: String { rawValue }
}

enum ProviderDataSource: String, Codable, CaseIterable, Identifiable {
    case localAdapter = "Local adapter"
    case officialAPI = "Official API"
    case manual = "Manual"
    case unknown = "Unknown"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .localAdapter:
            "Local"
        case .officialAPI:
            "API"
        case .manual:
            "Manual"
        case .unknown:
            "Setup"
        }
    }

    var color: Color {
        switch self {
        case .localAdapter:
            .green
        case .officialAPI:
            .blue
        case .manual:
            .orange
        case .unknown:
            .secondary
        }
    }
}
