import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

private enum UsageWindowMetrics {
    static let width: CGFloat = 460
    static let minimumHeight: CGFloat = 480
    static let maximumHeight: CGFloat = 1_000
}

private enum AppWindows {
    static let reports = "reports"
}

@main
struct VibeMeasureApp: App {
    @AppStorage("displayMode") private var displayMode = DisplayMode.providerCycles.rawValue
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("usagePopoverHeight") private var usagePopoverHeight = 620.0
    @StateObject private var appModel = VibeMeasureAppModel()

    var body: some Scene {
        MenuBarExtra("VibeMeasure", systemImage: "chart.bar.xaxis") {
            UsagePopover(
                displayMode: Binding(
                    get: { DisplayMode(rawValue: displayMode) ?? .providerCycles },
                    set: { displayMode = $0.rawValue }
                ),
                providerStore: appModel.providerStore,
                usageStore: appModel.usageStore
            )
            .frame(width: UsageWindowMetrics.width, height: CGFloat(usagePopoverHeight))
            .background(UsageWindowResizeConfigurator(height: $usagePopoverHeight))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                displayMode: $displayMode,
                launchAtLogin: $launchAtLogin,
                usagePopoverHeight: $usagePopoverHeight,
                providerStore: appModel.providerStore
            )
        }

        Window("Reports", id: AppWindows.reports) {
            ReportsView(
                providerStore: appModel.providerStore,
                usageStore: appModel.usageStore
            )
        }
        .defaultSize(width: 860, height: 620)
    }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case providerCycles = "Provider cycles"
    case fiveHours = "5 hours"
    case oneWeek = "1 week"
    case oneMonth = "1 month"

    var id: String { rawValue }

    var windowTitle: String {
        switch self {
        case .providerCycles:
            "Provider cycles"
        case .fiveHours:
            "5-Hour"
        case .oneWeek:
            "1 Week"
        case .oneMonth:
            "1 Month"
        }
    }
}

struct UsageWindowResizeConfigurator: NSViewRepresentable {
    @Binding var height: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.height = $height
        DispatchQueue.main.async {
            context.coordinator.configure(window: view.window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var height: Binding<Double>

        private weak var configuredWindow: NSWindow?
        private var isApplyingStoredSize = false

        init(height: Binding<Double>) {
            self.height = height
            super.init()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func configure(window: NSWindow?) {
            guard let window else {
                return
            }

            if configuredWindow !== window {
                if let configuredWindow {
                    NotificationCenter.default.removeObserver(
                        self,
                        name: NSWindow.didResizeNotification,
                        object: configuredWindow
                    )
                }

                configuredWindow = window
                window.styleMask.insert(.resizable)
                window.contentMinSize = NSSize(
                    width: UsageWindowMetrics.width,
                    height: UsageWindowMetrics.minimumHeight
                )
                window.contentMaxSize = NSSize(
                    width: UsageWindowMetrics.width,
                    height: UsageWindowMetrics.maximumHeight
                )

                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidResize(_:)),
                    name: NSWindow.didResizeNotification,
                    object: window,
                )
            }

            applyStoredHeight(to: window)
        }

        @objc
        private func windowDidResize(_ notification: Notification) {
            guard let resizedWindow = notification.object as? NSWindow else {
                return
            }
            storeHeight(from: resizedWindow)
        }

        private func applyStoredHeight(to window: NSWindow) {
            let storedHeight = Self.clampedHeight(CGFloat(height.wrappedValue))
            if abs(height.wrappedValue - Double(storedHeight)) > 0.5 {
                height.wrappedValue = Double(storedHeight)
            }

            let currentHeight = window.contentView?.bounds.height ?? window.frame.height
            guard abs(currentHeight - storedHeight) > 1 else {
                return
            }

            isApplyingStoredSize = true
            window.setContentSize(NSSize(width: UsageWindowMetrics.width, height: storedHeight))
            isApplyingStoredSize = false
        }

        private func storeHeight(from window: NSWindow) {
            guard !isApplyingStoredSize else {
                return
            }

            let contentHeight = window.contentView?.bounds.height ?? window.frame.height
            let clampedHeight = Self.clampedHeight(contentHeight)
            if abs(contentHeight - clampedHeight) > 1 {
                isApplyingStoredSize = true
                window.setContentSize(NSSize(width: UsageWindowMetrics.width, height: clampedHeight))
                isApplyingStoredSize = false
            }

            guard abs(height.wrappedValue - Double(clampedHeight)) > 0.5 else {
                return
            }
            height.wrappedValue = Double(clampedHeight)
        }

        private static func clampedHeight(_ height: CGFloat) -> CGFloat {
            min(max(height, UsageWindowMetrics.minimumHeight), UsageWindowMetrics.maximumHeight)
        }
    }
}

@MainActor
final class VibeMeasureAppModel: ObservableObject {
    let providerStore: ProviderSettingsStore
    let usageStore: UsageRefreshStore

    private var cancellables = Set<AnyCancellable>()

    init(
        providerStore: ProviderSettingsStore = ProviderSettingsStore(),
        usageStore: UsageRefreshStore = UsageRefreshStore()
    ) {
        self.providerStore = providerStore
        self.usageStore = usageStore

        usageStore.configure(providers: providerStore.providers)
        providerStore.$providers
            .sink { [weak usageStore] providers in
                usageStore?.configure(providers: providers)
            }
            .store(in: &cancellables)
    }
}

@MainActor
final class UsageRefreshStore: ObservableObject {
    @Published private(set) var liveUsageByProvider: [String: ProviderLiveUsage] = [:]
    @Published private(set) var refreshError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastPulledAtByProvider: [String: Date] = [:]

    private var providers: [ProviderSettings] = []
    private var errorsByProvider: [String: String] = [:]
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pullDueProviders()
            }
        }
    }

    func configure(providers: [ProviderSettings]) {
        synchronizeConfiguredProviders(providers)
        pullDueProviders()
    }

    func pullNow(providers: [ProviderSettings]) {
        synchronizeConfiguredProviders(providers)
        pullDueProviders(force: true)
    }

    private func synchronizeConfiguredProviders(_ providers: [ProviderSettings]) {
        self.providers = providers

        let liveProviderIDs = Set(providers.filter(\.canReadLiveUsage).map(\.id))
        liveUsageByProvider = liveUsageByProvider.filter { liveProviderIDs.contains($0.key) }
        lastPulledAtByProvider = lastPulledAtByProvider.filter { liveProviderIDs.contains($0.key) }
        errorsByProvider = errorsByProvider.filter { liveProviderIDs.contains($0.key) }
        updateRefreshError()
    }

    private func pullDueProviders(force: Bool = false, now: Date = Date()) {
        guard !isRefreshing else {
            return
        }

        let dueProviders = providers.filter { provider in
            shouldPull(provider: provider, now: now, force: force)
        }
        guard !dueProviders.isEmpty else {
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        for provider in dueProviders {
            pull(provider: provider, now: now)
        }
        updateRefreshError()
    }

    private func shouldPull(provider: ProviderSettings, now: Date, force: Bool) -> Bool {
        guard provider.canReadLiveUsage else {
            return false
        }

        if force || lastPulledAtByProvider[provider.id] == nil {
            return true
        }

        let interval = TimeInterval(max(provider.pollIntervalMinutes, 1) * 60)
        return now.timeIntervalSince(lastPulledAtByProvider[provider.id] ?? .distantPast) >= interval
    }

    private func pull(provider: ProviderSettings, now: Date) {
        do {
            if let usage = try readUsage(for: provider) {
                liveUsageByProvider[provider.id] = usage
                errorsByProvider.removeValue(forKey: provider.id)
            } else {
                liveUsageByProvider.removeValue(forKey: provider.id)
                errorsByProvider[provider.id] = "No Codex CLI token_count data found in ~/.codex/sessions."
            }
            lastPulledAtByProvider[provider.id] = now
        } catch {
            liveUsageByProvider.removeValue(forKey: provider.id)
            errorsByProvider[provider.id] = "Codex CLI data could not be read: \(error.localizedDescription)"
            lastPulledAtByProvider[provider.id] = now
        }
    }

    private func readUsage(for provider: ProviderSettings) throws -> ProviderLiveUsage? {
        switch provider.id {
        case "codex":
            try CodexCliUsageReader().readLatestUsage()
        case "minimax":
            try MiniMaxCliUsageReader(commandHint: provider.commandHint).readLatestUsage()
        default:
            nil
        }
    }

    private func updateRefreshError() {
        refreshError = errorsByProvider.values.isEmpty
            ? nil
            : errorsByProvider.values.sorted().joined(separator: " ")
    }
}

struct UsagePopover: View {
    @Environment(\.openWindow) private var openWindow
    @Binding var displayMode: DisplayMode
    @ObservedObject var providerStore: ProviderSettingsStore
    @ObservedObject var usageStore: UsageRefreshStore

    private var providers: [ProviderPreview] {
        providerStore.providers
            .filter(\.isEnabled)
            .map { provider in
                ProviderPreview(
                    settings: provider,
                    liveUsage: usageStore.liveUsageByProvider[provider.id]
                )
                .applying(displayMode: displayMode)
            }
    }

    private var statusBadge: (label: String, color: Color) {
        if usageStore.refreshError != nil {
            return ("Data issue", .red)
        }
        if usageStore.isRefreshing {
            return ("Refreshing", .blue)
        }
        if usageStore.liveUsageByProvider.isEmpty {
            return ("Manual data", .orange)
        }
        return ("CLI data", .green)
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

            if let refreshError = usageStore.refreshError {
                Text(refreshError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

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
            Text(statusBadge.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusBadge.color)
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                usageStore.pullNow(providers: providerStore.providers)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                usageStore.pullNow(providers: providerStore.providers)
                openWindow(id: AppWindows.reports)
            } label: {
                Label("Reports", systemImage: "doc.text.magnifyingglass")
            }

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }

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
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.headline)
                    if !provider.planName.isEmpty {
                        Text(provider.planName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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

enum ReportPeriod: String, CaseIterable, Identifiable {
    case currentWeek = "Current week"
    case currentMonth = "Current month"
    case currentYear = "Current year"
    case custom = "Custom"

    var id: String { rawValue }
}

struct ReportsView: View {
    @ObservedObject var providerStore: ProviderSettingsStore
    @ObservedObject var usageStore: UsageRefreshStore
    @State private var period = ReportPeriod.currentWeek
    @State private var customStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEndDate = Date()

    private var rows: [ReportSnapshotRow] {
        providerStore.providers
            .filter(\.isEnabled)
            .flatMap { provider in
                ProviderPreview(
                    settings: provider,
                    liveUsage: usageStore.liveUsageByProvider[provider.id]
                )
                .reportRows()
            }
    }

    private var periodLabel: String {
        switch period {
        case .currentWeek:
            "Current week"
        case .currentMonth:
            "Current month"
        case .currentYear:
            "Current year"
        case .custom:
            "\(customStartDate.formatted(date: .abbreviated, time: .omitted)) - \(customEndDate.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reports")
                    .font(.headline)
                Text(periodLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                usageStore.pullNow(providers: providerStore.providers)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Period", selection: $period) {
                ForEach(ReportPeriod.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)

            if period == .custom {
                HStack {
                    DatePicker("Start", selection: $customStartDate, displayedComponents: .date)
                    DatePicker("End", selection: $customEndDate, displayedComponents: .date)
                }
            }

            Text("The macOS app currently shows the latest live/manual snapshot. Historical XLSX/PDF export requires persisted SQLite usage events.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "No report data",
                systemImage: "chart.bar.doc.horizontal",
                description: Text("Enable a provider or add manual windows in Settings.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn("Provider", value: \.providerName)
                TableColumn("Plan", value: \.planName)
                TableColumn("Window", value: \.windowName)
                TableColumn("Usage", value: \.percentText)
                TableColumn("Source", value: \.source)
                TableColumn("Notes", value: \.notes)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Exports are disabled until the native app writes historical usage events to SQLite.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export XLSX") {}
                .disabled(true)
                .help("Requires persisted SQLite usage events.")
            Button("Export PDF") {}
                .disabled(true)
                .help("Requires persisted SQLite usage events.")
        }
        .padding(16)
        .background(.bar)
    }
}

struct ReportSnapshotRow: Identifiable {
    let id = UUID()
    let providerName: String
    let planName: String
    let windowName: String
    let percentText: String
    let source: String
    let notes: String
}

struct SettingsView: View {
    @Binding var displayMode: String
    @Binding var launchAtLogin: Bool
    @Binding var usagePopoverHeight: Double
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
                LabeledContent("Usage window height") {
                    Stepper(
                        "\(Int(usagePopoverHeight)) px",
                        value: $usagePopoverHeight,
                        in: Double(UsageWindowMetrics.minimumHeight)...Double(UsageWindowMetrics.maximumHeight),
                        step: 20
                    )
                    .frame(width: 140)
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
    let planName: String
    let symbol: String
    let status: String
    let statusColor: Color
    let windows: [WindowPreview]

    init(settings: ProviderSettings, liveUsage: ProviderLiveUsage? = nil) {
        id = settings.id
        name = settings.displayName
        planName = settings.planName.trimmingCharacters(in: .whitespacesAndNewlines)
        symbol = settings.symbolName
        if let liveUsage {
            status = liveUsage.status
            statusColor = liveUsage.statusColor
            windows = liveUsage.windows
        } else if settings.dataSource == .localAdapter && !settings.hasVerifiedLocalAdapter {
            status = "No adapter"
            statusColor = .orange
            windows = [
                WindowPreview(
                    name: "Usage unavailable",
                    percent: 0,
                    resetText: "No verified local usage source is implemented for \(settings.displayName)"
                )
            ]
        } else {
            status = settings.dataSource.shortLabel
            statusColor = settings.dataSource.color
            windows = settings.manualWindows.isEmpty
                ? [WindowPreview(name: "Manual setup required", percent: 0, resetText: "No limits are guessed")]
                : settings.manualWindows.map(WindowPreview.init(window:))
        }
    }

    private init(
        id: String,
        name: String,
        planName: String,
        symbol: String,
        status: String,
        statusColor: Color,
        windows: [WindowPreview]
    ) {
        self.id = id
        self.name = name
        self.planName = planName
        self.symbol = symbol
        self.status = status
        self.statusColor = statusColor
        self.windows = windows
    }

    func applying(displayMode: DisplayMode) -> ProviderPreview {
        guard displayMode != .providerCycles else {
            return self
        }

        let matchingWindows = windows.filter { window in
            window.matches(displayMode: displayMode)
        }

        return ProviderPreview(
            id: id,
            name: name,
            planName: planName,
            symbol: symbol,
            status: status,
            statusColor: statusColor,
            windows: matchingWindows.isEmpty
                ? [WindowPreview.manualSetupRequired(for: displayMode)]
                : matchingWindows
        )
    }

    func reportRows() -> [ReportSnapshotRow] {
        windows.map { window in
            ReportSnapshotRow(
                providerName: name,
                planName: planName.isEmpty ? "-" : planName,
                windowName: window.name,
                percentText: window.percentText,
                source: status,
                notes: window.resetText
            )
        }
    }
}

struct WindowPreview: Identifiable {
    let id = UUID()
    let name: String
    let percent: Double
    let resetText: String
    let displayModes: Set<DisplayMode>

    var percentText: String {
        "\(Int(percent * 100))%"
    }

    init(
        name: String,
        percent: Double,
        resetText: String,
        displayModes: Set<DisplayMode> = []
    ) {
        self.name = name
        self.percent = percent
        self.resetText = resetText
        self.displayModes = displayModes
    }

    init(window: ManualUsageWindow) {
        name = window.label.isEmpty ? window.kind.rawValue : window.label
        percent = min(max(window.usedPercent / 100, 0), 1)
        resetText = window.resetNote.isEmpty ? "Manual window" : window.resetNote
        displayModes = window.kind.displayModes
    }

    init(codexWindow: CodexRateLimitWindow) {
        name = Self.codexWindowName(minutes: codexWindow.windowMinutes)
        percent = min(max(codexWindow.usedPercent / 100, 0), 1)
        resetText = Self.codexResetText(resetsAt: Date(timeIntervalSince1970: codexWindow.resetsAt))
        displayModes = Self.codexDisplayModes(minutes: codexWindow.windowMinutes)
    }

    func matches(displayMode: DisplayMode) -> Bool {
        displayModes.contains(displayMode)
    }

    static func manualSetupRequired(for displayMode: DisplayMode) -> WindowPreview {
        WindowPreview(
            name: displayMode.windowTitle,
            percent: 0,
            resetText: "Manual setup required for this period",
            displayModes: [displayMode]
        )
    }

    private static func codexWindowName(minutes: Int) -> String {
        switch minutes {
        case 300:
            "5-Hour"
        case 10_080:
            "7-Day"
        case 40_320...44_640:
            "1 Month"
        default:
            "\(minutes) min"
        }
    }

    private static func codexDisplayModes(minutes: Int) -> Set<DisplayMode> {
        switch minutes {
        case 300:
            [.fiveHours]
        case 10_080:
            [.oneWeek]
        case 40_320...44_640:
            [.oneMonth]
        default:
            []
        }
    }

    private static func codexResetText(resetsAt: Date) -> String {
        let remainingSeconds = Int(resetsAt.timeIntervalSince(Date()))
        guard remainingSeconds > 0 else {
            return "Reset time passed; run Codex CLI and refresh"
        }

        let days = remainingSeconds / 86_400
        let hours = (remainingSeconds % 86_400) / 3_600
        let minutes = (remainingSeconds % 3_600) / 60

        if days > 0 {
            return "Resets in \(days)d \(hours)h"
        }
        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        }
        return "Resets in \(max(minutes, 1))m"
    }
}

struct ProviderLiveUsage {
    let status: String
    let statusColor: Color
    let windows: [WindowPreview]
}

struct CodexCliUsageReader {
    func readLatestUsage() throws -> ProviderLiveUsage? {
        let sessionRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")

        guard FileManager.default.fileExists(atPath: sessionRoot.path) else {
            return nil
        }

        let files = try codexSessionFiles(in: sessionRoot)
        var latestEvent: CodexTokenCountEvent?

        for file in files.prefix(80) {
            for event in try tokenCountEvents(in: file) {
                if latestEvent == nil || event.timestamp > latestEvent!.timestamp {
                    latestEvent = event
                }
            }
        }

        guard let latestEvent else {
            return nil
        }

        let windows = latestEvent.rateLimits.windows
        if windows.isEmpty {
            return ProviderLiveUsage(
                status: "Local",
                statusColor: .green,
                windows: [
                    WindowPreview(
                        name: "Token usage",
                        percent: 0,
                        resetText: "Latest Codex CLI event: \(Self.relativeTimestamp(latestEvent.timestamp))"
                    )
                ]
            )
        }

        return ProviderLiveUsage(
            status: "Local",
            statusColor: .green,
            windows: windows
        )
    }

    private func codexSessionFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl",
                  file.lastPathComponent.hasPrefix("rollout-") else {
                continue
            }

            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }

            files.append((file, values.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map(\.url)
    }

    private func tokenCountEvents(in file: URL) throws -> [CodexTokenCountEvent] {
        let rawContent = try String(contentsOf: file, encoding: .utf8)
        let decoder = JSONDecoder()
        var events: [CodexTokenCountEvent] = []

        for line in rawContent.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let envelope = try? decoder.decode(CodexEventEnvelope.self, from: data),
                  envelope.payload.type == "token_count",
                  let timestamp = Self.parseTimestamp(envelope.timestamp) else {
                continue
            }

            events.append(
                CodexTokenCountEvent(
                    timestamp: timestamp,
                    rateLimits: envelope.payload.rateLimits
                )
            )
        }

        return events
    }

    private static func parseTimestamp(_ rawValue: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: rawValue) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }

    private static func relativeTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct CodexTokenCountEvent {
    let timestamp: Date
    let rateLimits: CodexRateLimits
}

struct CodexEventEnvelope: Decodable {
    let timestamp: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let rateLimits: CodexRateLimits

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }
}

struct CodexRateLimits: Decodable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?

    var windows: [WindowPreview] {
        [primary, secondary]
            .compactMap(\.self)
            .map(WindowPreview.init(codexWindow:))
    }
}

struct CodexRateLimitWindow: Decodable {
    let resetsAt: TimeInterval
    let usedPercent: Double
    let windowMinutes: Int

    enum CodingKeys: String, CodingKey {
        case resetsAt = "resets_at"
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
    }
}

struct MiniMaxCliUsageReader {
    let commandHint: String

    func readLatestUsage() throws -> ProviderLiveUsage? {
        let output = try runQuotaCommand()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(MiniMaxQuotaResponse.self, from: output)
        guard response.baseResp.statusCode == 0 else {
            throw LocalUsageReaderError.invalidResponse(response.baseResp.statusMsg)
        }

        let windows = response.modelRemains.flatMap(\.windows)
        guard !windows.isEmpty else {
            return nil
        }

        return ProviderLiveUsage(
            status: "Local",
            statusColor: .green,
            windows: windows
        )
    }

    private func runQuotaCommand() throws -> Data {
        let command = commandHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let quotaArguments = ["quota", "show", "--output", "json", "--quiet", "--non-interactive"]

        if let executableURL = executableURL(for: command) {
            process.executableURL = executableURL
            process.arguments = quotaArguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [(command.isEmpty ? "mmx" : command)] + quotaArguments
        }

        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            return outputData
        }

        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorText = Self.redactedSecretText(
            String(data: errorData, encoding: .utf8) ?? "No stderr output"
        )
        throw LocalUsageReaderError.commandFailed(
            command: "mmx quota show",
            status: Int(process.terminationStatus),
            stderr: errorText
        )
    }

    private func executableURL(for command: String) -> URL? {
        let fileManager = FileManager.default
        if command.hasPrefix("/"), fileManager.isExecutableFile(atPath: command) {
            return URL(fileURLWithPath: command)
        }

        for path in ["/opt/homebrew/bin/mmx", "/usr/local/bin/mmx"] where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private static func redactedSecretText(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"sk-[A-Za-z0-9_-]+"#,
            with: "sk-[redacted]",
            options: .regularExpression
        )
    }
}

enum LocalUsageReaderError: LocalizedError {
    case commandFailed(command: String, status: Int, stderr: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, stderr):
            "\(command) failed with exit code \(status): \(stderr)"
        case let .invalidResponse(message):
            "Unexpected usage response: \(message)"
        }
    }
}

struct MiniMaxQuotaResponse: Decodable {
    let modelRemains: [MiniMaxModelRemain]
    let baseResp: MiniMaxBaseResponse
}

struct MiniMaxBaseResponse: Decodable {
    let statusCode: Int
    let statusMsg: String
}

struct MiniMaxModelRemain: Decodable {
    let startTime: Int64
    let endTime: Int64
    let remainsTime: Int64
    let currentIntervalTotalCount: Int
    let currentIntervalUsageCount: Int
    let modelName: String
    let currentWeeklyTotalCount: Int
    let currentWeeklyUsageCount: Int
    let weeklyStartTime: Int64
    let weeklyEndTime: Int64
    let weeklyRemainsTime: Int64
    let currentIntervalRemainingPercent: Double
    let currentWeeklyRemainingPercent: Double

    var windows: [WindowPreview] {
        [
            WindowPreview(
                name: "\(modelLabel) 5-Hour",
                percent: Self.usedPercent(
                    usageCount: currentIntervalUsageCount,
                    totalCount: currentIntervalTotalCount,
                    remainingPercent: currentIntervalRemainingPercent
                ),
                resetText: Self.resetText(
                    remainingMilliseconds: remainsTime,
                    endMilliseconds: endTime,
                    usageCount: currentIntervalUsageCount,
                    totalCount: currentIntervalTotalCount,
                    remainingPercent: currentIntervalRemainingPercent
                ),
                displayModes: [.fiveHours]
            ),
            WindowPreview(
                name: "\(modelLabel) 1 Week",
                percent: Self.usedPercent(
                    usageCount: currentWeeklyUsageCount,
                    totalCount: currentWeeklyTotalCount,
                    remainingPercent: currentWeeklyRemainingPercent
                ),
                resetText: Self.resetText(
                    remainingMilliseconds: weeklyRemainsTime,
                    endMilliseconds: weeklyEndTime,
                    usageCount: currentWeeklyUsageCount,
                    totalCount: currentWeeklyTotalCount,
                    remainingPercent: currentWeeklyRemainingPercent
                ),
                displayModes: [.oneWeek]
            )
        ]
    }

    private var modelLabel: String {
        modelName.isEmpty ? "MiniMAX" : modelName
    }

    private static func usedPercent(usageCount: Int, totalCount: Int, remainingPercent: Double) -> Double {
        if totalCount > 0 {
            return min(max(Double(usageCount) / Double(totalCount), 0), 1)
        }

        return min(max(1 - remainingPercent / 100, 0), 1)
    }

    private static func resetText(
        remainingMilliseconds: Int64,
        endMilliseconds: Int64,
        usageCount: Int,
        totalCount: Int,
        remainingPercent: Double
    ) -> String {
        let resetPrefix = resetPrefix(
            remainingMilliseconds: remainingMilliseconds,
            endMilliseconds: endMilliseconds
        )

        if totalCount > 0 {
            return "\(resetPrefix); \(usageCount)/\(totalCount) used"
        }

        return "\(resetPrefix); remaining \(Int(remainingPercent))%"
    }

    private static func resetPrefix(remainingMilliseconds: Int64, endMilliseconds: Int64) -> String {
        if remainingMilliseconds > 0 {
            return "Resets in \(durationText(seconds: remainingMilliseconds / 1_000))"
        }

        let endDate = Date(timeIntervalSince1970: TimeInterval(endMilliseconds) / 1_000)
        let remainingSeconds = Int(endDate.timeIntervalSince(Date()))
        guard remainingSeconds > 0 else {
            return "Reset time passed; refresh MiniMAX"
        }
        return "Resets in \(durationText(seconds: Int64(remainingSeconds)))"
    }

    private static func durationText(seconds: Int64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(minutes, 1))m"
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
                TextField("Plan name", text: $provider.planName)
                TextField("Command hint", text: $provider.commandHint)
                TextField("SF Symbol", text: $provider.symbolName)
                Picker("Data source", selection: $provider.dataSource) {
                    ForEach(ProviderDataSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                LabeledContent("Pull interval") {
                    Stepper(
                        "\(provider.pollIntervalMinutes) min",
                        value: $provider.pollIntervalMinutes,
                        in: 1...120,
                        step: 1
                    )
                    .frame(width: 130)
                }
                Toggle("Enabled in popover and widget", isOn: $provider.isEnabled)
                if provider.dataSource == .localAdapter && !provider.hasVerifiedLocalAdapter {
                    Text("No verified local usage adapter exists for this provider yet. Use manual windows for now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    private static let currentStorageVersion = 4

    init() {
        var loadedProviders = loadProviders()
        let storedVersion = UserDefaults.standard.integer(forKey: storageVersionKey)
        if storedVersion < 2 {
            loadedProviders = loadedProviders.map { provider in
                var migratedProvider = provider
                migratedProvider.isEnabled = false
                return migratedProvider
            }
        }
        if storedVersion < 4 {
            loadedProviders = Self.providersWithMiniMaxAdapterDefaults(loadedProviders)
        }
        if storedVersion < Self.currentStorageVersion {
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
        .builtIn(
            id: "minimax",
            displayName: "MiniMAX",
            planName: "Token Plan",
            commandHint: "mmx",
            symbolName: "m.square",
            dataSource: .localAdapter
        )
    ]

    private static func providersWithMiniMaxAdapterDefaults(_ providers: [ProviderSettings]) -> [ProviderSettings] {
        providers.map { provider in
            guard provider.id == "minimax" else {
                return provider
            }

            var migratedProvider = provider
            if migratedProvider.planName.isEmpty {
                migratedProvider.planName = "Token Plan"
            }
            if migratedProvider.commandHint.isEmpty {
                migratedProvider.commandHint = "mmx"
            }
            if migratedProvider.dataSource == .manual, migratedProvider.manualWindows.isEmpty {
                migratedProvider.dataSource = .localAdapter
            }
            return migratedProvider
        }
    }
}

struct ProviderSettings: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var planName: String
    var commandHint: String
    var symbolName: String
    var dataSource: ProviderDataSource
    var isBuiltIn: Bool
    var isEnabled: Bool
    var pollIntervalMinutes: Int
    var manualWindows: [ManualUsageWindow]

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case planName
        case commandHint
        case symbolName
        case dataSource
        case isBuiltIn
        case isEnabled
        case pollIntervalMinutes
        case manualWindows
    }

    init(
        id: String,
        displayName: String,
        planName: String = "",
        commandHint: String,
        symbolName: String,
        dataSource: ProviderDataSource,
        isBuiltIn: Bool,
        isEnabled: Bool,
        pollIntervalMinutes: Int = 5,
        manualWindows: [ManualUsageWindow]
    ) {
        self.id = id
        self.displayName = displayName
        self.planName = planName
        self.commandHint = commandHint
        self.symbolName = symbolName
        self.dataSource = dataSource
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.pollIntervalMinutes = pollIntervalMinutes
        self.manualWindows = manualWindows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        planName = try container.decodeIfPresent(String.self, forKey: .planName) ?? ""
        commandHint = try container.decode(String.self, forKey: .commandHint)
        symbolName = try container.decode(String.self, forKey: .symbolName)
        dataSource = try container.decode(ProviderDataSource.self, forKey: .dataSource)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        pollIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .pollIntervalMinutes) ?? 5
        manualWindows = try container.decode([ManualUsageWindow].self, forKey: .manualWindows)
    }

    static func builtIn(
        id: String,
        displayName: String,
        planName: String = "",
        commandHint: String,
        symbolName: String,
        dataSource: ProviderDataSource = .manual
    ) -> ProviderSettings {
        ProviderSettings(
            id: id,
            displayName: displayName,
            planName: planName,
            commandHint: commandHint,
            symbolName: symbolName,
            dataSource: dataSource,
            isBuiltIn: true,
            isEnabled: false,
            pollIntervalMinutes: 5,
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
            pollIntervalMinutes: 5,
            manualWindows: []
        )
    }

    var hasVerifiedLocalAdapter: Bool {
        id == "codex" || id == "minimax"
    }

    var canReadLiveUsage: Bool {
        isEnabled && dataSource == .localAdapter && hasVerifiedLocalAdapter
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

    var displayModes: Set<DisplayMode> {
        switch self {
        case .fiveHours:
            [.fiveHours]
        case .oneWeek:
            [.oneWeek]
        case .oneMonth:
            [.oneMonth]
        case .custom:
            []
        }
    }
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
