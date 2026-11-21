import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

private enum UsageWindowMetrics {
    static let width: CGFloat = 460
    static let minimumHeight: CGFloat = 480
    static let maximumHeight: CGFloat = 1_000
}

private enum AppWindows {
    static let usage = "usage"
    static let reports = "reports"
}

@main
struct VibeMeasureApp: App {
    @AppStorage("displayMode") private var displayMode = DisplayMode.providerCycles.rawValue
    @AppStorage("usagePopoverHeight") private var usagePopoverHeight = 620.0
    @StateObject private var appModel = VibeMeasureAppModel()

    var body: some Scene {
        MenuBarExtra("VibeMeasure", systemImage: "chart.bar.xaxis") {
            usageMonitorContent
            .frame(width: UsageWindowMetrics.width, height: CGFloat(usagePopoverHeight))
            .background(UsageWindowResizeConfigurator(height: $usagePopoverHeight))
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Usage Monitor", id: AppWindows.usage) {
            usageMonitorContent
                .frame(minWidth: UsageWindowMetrics.width, minHeight: UsageWindowMetrics.minimumHeight)
        }
        .defaultSize(width: UsageWindowMetrics.width, height: CGFloat(usagePopoverHeight))

        Settings {
            SettingsView(
                displayMode: $displayMode,
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

    private var usageDisplayMode: Binding<DisplayMode> {
        Binding(
            get: { DisplayMode(rawValue: displayMode) ?? .providerCycles },
            set: { displayMode = $0.rawValue }
        )
    }

    private var usageMonitorContent: some View {
        UsagePopover(
            displayMode: usageDisplayMode,
            providerStore: appModel.providerStore,
            usageStore: appModel.usageStore
        )
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

        providerStore.$providers.combineLatest(usageStore.$liveUsageByProvider)
            .sink { providers, readings in
                WidgetSnapshotWriter.publish(providers: providers, readings: readings)
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
    private var pollingTask: Task<Void, Never>?
    private var inFlight: [String: UUID] = [:]
    private var repeatAfterPull: Set<String> = []

    init() {
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else {
                    return
                }
                self?.pullDueProviders()
            }
        }
    }

    deinit {
        pollingTask?.cancel()
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
        let previous = self.providers
        self.providers = providers
        // Poll intervals and labels can change without invalidating a reading.
        let retainedIDs = Set(providers.filter { provider in
            provider.canReadLiveUsage && previous.contains {
                $0.id == provider.id && $0.canReadLiveUsage && $0.commandHint == provider.commandHint
            }
        }.map(\.id))
        inFlight = inFlight.filter { retainedIDs.contains($0.key) }
        repeatAfterPull.formIntersection(retainedIDs)
        liveUsageByProvider = liveUsageByProvider.filter { retainedIDs.contains($0.key) }
        lastPulledAtByProvider = lastPulledAtByProvider.filter { retainedIDs.contains($0.key) }
        errorsByProvider = errorsByProvider.filter { retainedIDs.contains($0.key) }
        isRefreshing = !inFlight.isEmpty
        updateRefreshError()
    }

    private func pullDueProviders(force: Bool = false, now: Date = Date()) {
        for provider in providers where provider.canReadLiveUsage {
            if inFlight[provider.id] != nil {
                if force { repeatAfterPull.insert(provider.id) }
                continue
            }
            let interval = TimeInterval(max(provider.pollIntervalMinutes, 1)) * 60
            if force || now.timeIntervalSince(lastPulledAtByProvider[provider.id] ?? .distantPast) >= interval {
                startPull(provider)
            }
        }
    }

    private func startPull(_ provider: ProviderSettings) {
        let requestID = UUID()
        inFlight[provider.id] = requestID
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try Self.readUsage(for: provider) }
            Task { @MainActor [weak self] in
                self?.finishPull(provider: provider, requestID: requestID, result: result)
            }
        }
    }

    private func finishPull(provider: ProviderSettings, requestID: UUID, result: Result<ProviderLiveUsage?, Error>) {
        guard inFlight[provider.id] == requestID else { return }
        inFlight.removeValue(forKey: provider.id)
        switch result {
        case let .success(usage):
            liveUsageByProvider[provider.id] = usage
            errorsByProvider[provider.id] = usage == nil ? "No live usage data found for \(provider.displayName)." : nil
        case let .failure(error):
            liveUsageByProvider.removeValue(forKey: provider.id)
            errorsByProvider[provider.id] = "\(provider.displayName) live usage could not be read: \(error.localizedDescription)"
        }
        lastPulledAtByProvider[provider.id] = Date()
        updateRefreshError()

        if repeatAfterPull.remove(provider.id) != nil {
            startPull(provider)
        } else {
            isRefreshing = !inFlight.isEmpty
        }
    }

    private nonisolated static func readUsage(for provider: ProviderSettings) throws -> ProviderLiveUsage? {
        switch provider.id {
        case "claude":
            try ClaudeCodeUsageReader().readLatestUsage()
        case "codex":
            try CodexCliUsageReader().readLatestUsage()
        case "gemini":
            try GeminiCliUsageReader().readLatestUsage()
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
                .applying(displayMode: displayMode, history: usageStore.liveUsageByProvider[provider.id]?.tokenHistory ?? [])
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
                    .font(.callout)
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
                                .font(.title3.weight(.semibold))
                            Text("Open Settings to enable or add providers.")
                                .font(.callout)
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
                .font(.title3.weight(.semibold))
            Spacer()
            Text(statusBadge.label)
                .font(.callout.weight(.semibold))
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
        .font(.callout)
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
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.title3.weight(.semibold))
                    if !provider.planName.isEmpty {
                        Text(provider.planName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(provider.status)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(provider.statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(provider.statusColor.opacity(0.12), in: Capsule())
            }

            ForEach(provider.windows) { window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(window.name)
                            .font(.body.weight(.semibold))
                        Spacer()
                        Text(window.percentText)
                            .font(.body.weight(.bold))
                            .foregroundStyle(.green)
                    }
                    if window.hasKnownPercent {
                        ProgressView(value: window.percent)
                            .tint(.green)
                    }
                    Text(window.resetText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum ReportPeriod: String, CaseIterable, Identifiable {
    case snapshot = "Current snapshot"
    case currentWeek = "Current week"
    case currentMonth = "Current month"
    case currentYear = "Current year"
    case custom = "Custom"

    var id: String { rawValue }

    var fileNameComponent: String {
        switch self {
        case .snapshot:
            "snapshot"
        case .currentWeek:
            "current-week"
        case .currentMonth:
            "current-month"
        case .currentYear:
            "current-year"
        case .custom:
            "custom"
        }
    }
}

struct ReportsView: View {
    @ObservedObject var providerStore: ProviderSettingsStore
    @ObservedObject var usageStore: UsageRefreshStore
    @State private var period = ReportPeriod.snapshot
    @State private var customStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEndDate = Date()
    @State private var exportStatus: String?
    @State private var exportError: String?

    @State private var databaseURL: URL?
    @State private var databaseRevision = 0
    @State private var loadedQuery: ImportedUsageQuery?
    @State private var imported: [String: TokenPeriodSummary] = [:]
    @State private var databaseError: String?

    private var dateRange: Range<Date>? {
        UsagePeriods.range(period, at: Date(), from: customStartDate, through: customEndDate)
    }

    private var databaseQuery: ImportedUsageQuery? {
        guard let url = databaseURL, let range = dateRange else { return nil }
        return ImportedUsageQuery(url: url, range: range, revision: databaseRevision)
    }

    private var rows: [ReportSnapshotRow] {
        let providers = providerStore.providers.filter(\.isEnabled)
        if period == .snapshot {
            return providers.flatMap { provider in
                ProviderPreview(settings: provider, liveUsage: usageStore.liveUsageByProvider[provider.id]).reportRows()
            }
        }
        guard let range = dateRange else { return [] }
        if let query = databaseQuery, loadedQuery != query { return [] }
        return providers.compactMap { provider in
            let summary = databaseURL != nil
                ? imported[provider.id]
                : TokenPeriodSummary.summarize(usageStore.liveUsageByProvider[provider.id]?.tokenHistory ?? [], in: range)
            guard let summary else { return nil }
            return ReportSnapshotRow(providerName: provider.displayName, planName: "—",
                                     windowName: "Recorded tokens", percentText: summary.tokens.formatted(),
                                     source: databaseURL == nil ? "Session logs" : "SQLite",
                                     notes: "\(summary.count) events")
        }
    }

    @MainActor
    private func loadDatabase(_ query: ImportedUsageQuery?) async {
        databaseError = nil
        loadedQuery = nil
        imported = [:]
        guard let query else { return }
        do {
            let result = try await Task.detached(priority: .utility) { try query.read() }.value
            guard !Task.isCancelled else { return }
            imported = result
            loadedQuery = query
        } catch {
            guard !Task.isCancelled else { return }
            databaseError = error.localizedDescription
        }
    }

    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use database"
        if panel.runModal() == .OK, let url = panel.url {
            databaseURL = url
            databaseRevision += 1
        }
    }

    private var periodLabel: String {
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UsagePeriods.utc.timeZone)
        return switch period {
        case .snapshot:
            "Current snapshot"
        case .currentWeek:
            "Current week"
        case .currentMonth:
            "Current month"
        case .currentYear:
            "Current year"
        case .custom:
            "\(customStartDate.formatted(format)) – \(customEndDate.formatted(format)) UTC"
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
        .task(id: databaseQuery) { await loadDatabase(databaseQuery) }
        .environment(\.timeZone, UsagePeriods.utc.timeZone)
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
                databaseRevision += 1
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

            if period != .snapshot {
                HStack {
                    Text(databaseURL?.lastPathComponent ?? "Source: available local session logs")
                    Button("Choose VibeMeasure database…") { chooseDatabase() }
                    if databaseURL != nil {
                        Button("Use session logs") { databaseURL = nil }
                    }
                }
                .font(.caption)
                if let databaseError {
                    Text(databaseError).foregroundStyle(.red)
                }
            }
            if let exportStatus {
                Text(exportStatus)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "No report data",
                systemImage: "chart.bar.doc.horizontal",
                description: Text(period == .snapshot
                    ? "Enable a provider in Settings."
                    : (dateRange == nil ? "Choose an end date on or after the start date."
                                        : "No recorded token events for enabled providers in this period."))
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
            Text(period == .snapshot ? "Current provider windows" : "Recorded token events in the selected UTC period")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export XLSX") {
                export(.xlsx)
            }
            .disabled(rows.isEmpty)
            Button("Export PDF") {
                export(.pdf)
            }
            .disabled(rows.isEmpty)
        }
        .padding(16)
        .background(.bar)
    }

    private func export(_ format: ReportExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "VibeMeasure-\(period.fileNameComponent).\(format.fileExtension)"
        if let contentType = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [contentType]
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let report = SnapshotReport(
            periodLabel: periodLabel,
            generatedAt: Date(),
            rows: rows,
            isSnapshot: period == .snapshot
        )

        do {
            try SnapshotReportExporter.write(report, format: format, to: url)
            exportError = nil
            exportStatus = "Exported \(url.lastPathComponent)"
        } catch {
            exportStatus = nil
            exportError = error.localizedDescription
        }
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

private extension ReportSnapshotRow {
    var usageFraction: Double? {
        guard percentText.hasSuffix("%"), let value = Double(percentText.dropLast()), value.isFinite else { return nil }
        return min(max(value / 100, 0), 1)
    }
}

enum ReportExportFormat {
    case xlsx
    case pdf

    var fileExtension: String {
        switch self {
        case .xlsx:
            "xlsx"
        case .pdf:
            "pdf"
        }
    }
}

struct SnapshotReport {
    let periodLabel: String
    let generatedAt: Date
    let rows: [ReportSnapshotRow]
    var isSnapshot = true

    var scope: String {
        isSnapshot ? "Current provider windows" : "Recorded token usage in the selected UTC period"
    }
}

private extension SnapshotReport {
    var averageUsagePercentText: String {
        let values = rows.compactMap(\.usageFraction)
        guard !values.isEmpty else { return "—" }
        let average = values.reduce(0, +) / Double(values.count)
        return "\(Int((average * 100).rounded()))%"
    }
}

enum ReportExportError: LocalizedError {
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case let .zipFailed(stderr):
            "XLSX export failed: \(stderr)"
        }
    }
}

struct SnapshotReportExporter {
    static func write(_ report: SnapshotReport, format: ReportExportFormat, to url: URL) throws {
        switch format {
        case .xlsx:
            try writeXLSX(report, to: url)
        case .pdf:
            try writePDF(report, to: url)
        }
    }

    private static func writeXLSX(_ report: SnapshotReport, to url: URL) throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("VibeMeasureReport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        try createDirectory("_rels", in: temporaryRoot)
        try createDirectory("xl/_rels", in: temporaryRoot)
        try createDirectory("xl/worksheets", in: temporaryRoot)

        try writeXML(contentTypesXML, to: temporaryRoot.appendingPathComponent("[Content_Types].xml"))
        try writeXML(rootRelationshipsXML, to: temporaryRoot.appendingPathComponent("_rels/.rels"))
        try writeXML(workbookXML, to: temporaryRoot.appendingPathComponent("xl/workbook.xml"))
        try writeXML(workbookRelationshipsXML, to: temporaryRoot.appendingPathComponent("xl/_rels/workbook.xml.rels"))
        try writeXML(worksheetXML(for: report), to: temporaryRoot.appendingPathComponent("xl/worksheets/sheet1.xml"))

        let archive = fileManager.temporaryDirectory.appendingPathComponent("VibeMeasure-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: archive) }
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = temporaryRoot
        process.arguments = ["-q", "-r", archive.path, "."]
        process.standardError = standardError
        try process.run()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorOutput, encoding: .utf8)
                ?? "zip exited with code \(process.terminationStatus)"
            throw ReportExportError.zipFailed(stderr)
        }
        try Data(contentsOf: archive, options: .mappedIfSafe).write(to: url, options: .atomic)
    }

    private static func writePDF(_ report: SnapshotReport, to url: URL) throws {
        try DesignedPDFReportRenderer.write(report, to: url)
    }

    private static func createDirectory(_ path: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private static func writeXML(_ xml: String, to url: URL) throws {
        try Data(xml.utf8).write(to: url, options: .atomic)
    }

    private static var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """
    }

    private static var rootRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
    }

    private static var workbookXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Report" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """
    }

    private static var workbookRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """
    }

    private static func worksheetXML(for report: SnapshotReport) -> String {
        let rows = report.spreadsheetRows()
        let sheetRows = rows.enumerated()
            .map { rowIndex, columns in
                let rowNumber = rowIndex + 1
                let cells = columns.enumerated()
                    .map { columnIndex, value in
                        let reference = "\(columnName(for: columnIndex))\(rowNumber)"
                        return #"<c r="\#(reference)" t="inlineStr"><is><t>\#(xmlEscaped(value))</t></is></c>"#
                    }
                    .joined()
                return #"<row r="\#(rowNumber)">\#(cells)</row>"#
            }
            .joined()

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>\(sheetRows)</sheetData>
        </worksheet>
        """
    }

    private static func columnName(for index: Int) -> String {
        let scalars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if index < scalars.count {
            return String(scalars[index])
        }
        return "A\(String(scalars[index % scalars.count]))"
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

}

struct DesignedPDFReportRenderer {
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 42
    private static let headerHeight: CGFloat = 118
    private static let cardHeight: CGFloat = 70
    private static let tableHeaderHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 38

    static func write(_ report: SnapshotReport, to url: URL) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let rowsPerFirstPage = max(Int((pageSize.height - headerHeight - cardHeight - tableHeaderHeight - 145) / rowHeight), 1)
        let rowsPerFollowingPage = max(Int((pageSize.height - headerHeight - tableHeaderHeight - 95) / rowHeight), 1)
        var remainingRows = report.rows
        var pageNumber = 1

        repeat {
            let isFirstPage = pageNumber == 1
            let pageRows = Array(remainingRows.prefix(isFirstPage ? rowsPerFirstPage : rowsPerFollowingPage))
            remainingRows.removeFirst(min(pageRows.count, remainingRows.count))

            context.beginPDFPage(nil)
            drawPage(report: report, rows: pageRows, pageNumber: pageNumber, isFirstPage: isFirstPage, in: context)
            context.endPDFPage()
            pageNumber += 1
        } while !remainingRows.isEmpty

        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    private static func drawPage(
        report: SnapshotReport,
        rows: [ReportSnapshotRow],
        pageNumber: Int,
        isFirstPage: Bool,
        in context: CGContext
    ) {
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }

        drawBackground()
        drawHeader(report: report, pageNumber: pageNumber)

        var tableTop = pageSize.height - headerHeight - 28
        if isFirstPage {
            drawSummaryCards(report: report, top: tableTop)
            tableTop -= cardHeight + 26
        }

        drawTable(rows: rows, top: tableTop)
        drawFooter(scope: report.scope)
    }

    private static func drawBackground() {
        NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: pageSize)).fill()

        NSColor.white.setFill()
        roundedRect(
            x: margin - 12,
            y: margin - 10,
            width: pageSize.width - margin * 2 + 24,
            height: pageSize.height - margin * 2 + 20,
            radius: 12
        ).fill()
    }

    private static func drawHeader(report: SnapshotReport, pageNumber: Int) {
        NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.16, alpha: 1).setFill()
        roundedRect(
            x: margin,
            y: pageSize.height - margin - 86,
            width: pageSize.width - margin * 2,
            height: 86,
            radius: 12
        ).fill()

        NSColor(calibratedRed: 0.15, green: 0.82, blue: 0.39, alpha: 1).setFill()
        roundedRect(
            x: margin + 18,
            y: pageSize.height - margin - 70,
            width: 8,
            height: 48,
            radius: 4
        ).fill()

        drawText(
            "VibeMeasure Report",
            in: CGRect(x: margin + 40, y: pageSize.height - margin - 40, width: 310, height: 22),
            font: .systemFont(ofSize: 20, weight: .bold),
            color: .white
        )
        drawText(
            report.periodLabel,
            in: CGRect(x: margin + 40, y: pageSize.height - margin - 64, width: 330, height: 18),
            font: .systemFont(ofSize: 11, weight: .medium),
            color: NSColor(calibratedWhite: 0.82, alpha: 1)
        )
        drawText(
            report.generatedAt.formatted(date: .abbreviated, time: .shortened),
            in: CGRect(x: pageSize.width - margin - 180, y: pageSize.height - margin - 39, width: 160, height: 18),
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            color: NSColor(calibratedWhite: 0.88, alpha: 1),
            alignment: .right
        )
        drawText(
            "Page \(pageNumber)",
            in: CGRect(x: pageSize.width - margin - 180, y: pageSize.height - margin - 62, width: 160, height: 18),
            font: .systemFont(ofSize: 10, weight: .regular),
            color: NSColor(calibratedWhite: 0.72, alpha: 1),
            alignment: .right
        )
    }

    private static func drawSummaryCards(report: SnapshotReport, top: CGFloat) {
        let cardWidth = (pageSize.width - margin * 2 - 20) / 3
        let cards = [
            ("Providers", "\(Set(report.rows.map(\.providerName)).count)", "Enabled in report"),
            ("Rows", "\(report.rows.count)", report.isSnapshot ? "Provider windows" : "Provider totals"),
            report.isSnapshot ? ("Avg. Usage", report.averageUsagePercentText, "Reported percentages")
                              : ("Time zone", "UTC", "Event timestamps")
        ]

        for (index, card) in cards.enumerated() {
            let x = margin + CGFloat(index) * (cardWidth + 10)
            let y = top - cardHeight
            NSColor(calibratedRed: 0.98, green: 0.99, blue: 0.99, alpha: 1).setFill()
            roundedRect(x: x, y: y, width: cardWidth, height: cardHeight, radius: 10).fill()
            NSColor(calibratedWhite: 0.88, alpha: 1).setStroke()
            roundedRect(x: x, y: y, width: cardWidth, height: cardHeight, radius: 10).stroke()

            drawText(
                card.0,
                in: CGRect(x: x + 14, y: y + 42, width: cardWidth - 28, height: 14),
                font: .systemFont(ofSize: 9, weight: .semibold),
                color: NSColor(calibratedWhite: 0.36, alpha: 1)
            )
            drawText(
                card.1,
                in: CGRect(x: x + 14, y: y + 19, width: cardWidth - 28, height: 22),
                font: .systemFont(ofSize: 19, weight: .bold),
                color: NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.16, alpha: 1)
            )
            drawText(
                card.2,
                in: CGRect(x: x + 14, y: y + 7, width: cardWidth - 28, height: 12),
                font: .systemFont(ofSize: 8.5, weight: .regular),
                color: NSColor(calibratedWhite: 0.48, alpha: 1)
            )
        }
    }

    private static func drawTable(rows: [ReportSnapshotRow], top: CGFloat) {
        let tableX = margin
        let tableWidth = pageSize.width - margin * 2
        let columnWidths: [CGFloat] = [110, 82, 108, 88, 72, tableWidth - 460]
        let headers = ["Provider", "Plan", "Window", "Usage", "Source", "Notes"]

        NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.20, alpha: 1).setFill()
        roundedRect(x: tableX, y: top - tableHeaderHeight, width: tableWidth, height: tableHeaderHeight, radius: 8).fill()

        var currentX = tableX + 10
        for (index, header) in headers.enumerated() {
            drawText(
                header,
                in: CGRect(x: currentX, y: top - 20, width: columnWidths[index] - 12, height: 13),
                font: .systemFont(ofSize: 8.5, weight: .bold),
                color: .white
            )
            currentX += columnWidths[index]
        }

        for (rowIndex, row) in rows.enumerated() {
            let y = top - tableHeaderHeight - CGFloat(rowIndex + 1) * rowHeight
            (rowIndex.isMultiple(of: 2)
                ? NSColor(calibratedWhite: 0.985, alpha: 1)
                : NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.98, alpha: 1)
            ).setFill()
            NSBezierPath(rect: CGRect(x: tableX, y: y, width: tableWidth, height: rowHeight)).fill()

            let values = [row.providerName, row.planName, row.windowName, row.percentText, row.source, row.notes]
            currentX = tableX + 10
            for (columnIndex, value) in values.enumerated() {
                let rect = CGRect(x: currentX, y: y + 12, width: columnWidths[columnIndex] - 12, height: 16)
                if columnIndex == 3 {
                    drawUsageCell(row: row, in: rect)
                } else {
                    drawText(
                        value,
                        in: rect,
                        font: .systemFont(ofSize: columnIndex == 0 ? 9.5 : 8.5, weight: columnIndex == 0 ? .semibold : .regular),
                        color: NSColor(calibratedWhite: columnIndex == 5 ? 0.38 : 0.18, alpha: 1)
                    )
                }
                currentX += columnWidths[columnIndex]
            }
        }
    }

    private static func drawUsageCell(row: ReportSnapshotRow, in rect: CGRect) {
        guard let fraction = row.usageFraction else {
            drawText(row.percentText, in: rect, font: .systemFont(ofSize: 9), color: .black)
            return
        }
        let barRect = CGRect(x: rect.minX, y: rect.minY + 1, width: 44, height: 8)
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        roundedRect(x: barRect.minX, y: barRect.minY, width: barRect.width, height: barRect.height, radius: 4).fill()

        let fillWidth = barRect.width * CGFloat(fraction)
        NSColor(calibratedRed: 0.15, green: 0.82, blue: 0.39, alpha: 1).setFill()
        roundedRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height, radius: 4).fill()

        drawText(
            row.percentText,
            in: CGRect(x: rect.minX + 50, y: rect.minY - 1, width: rect.width - 50, height: 14),
            font: .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
            color: NSColor(calibratedWhite: 0.18, alpha: 1)
        )
    }

    private static func drawFooter(scope: String) {
        NSColor(calibratedWhite: 0.84, alpha: 1).setStroke()
        NSBezierPath.strokeLine(
            from: CGPoint(x: margin, y: margin - 2),
            to: CGPoint(x: pageSize.width - margin, y: margin - 2)
        )
        drawText(
            scope,
            in: CGRect(x: margin, y: margin - 25, width: pageSize.width - margin * 2, height: 14),
            font: .systemFont(ofSize: 8.5, weight: .regular),
            color: NSColor(calibratedWhite: 0.46, alpha: 1)
        )
    }

    private static func drawText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSString(string: text).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func roundedRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius)
    }
}

private extension SnapshotReport {
    func spreadsheetRows() -> [[String]] {
        [
            ["VibeMeasure Report"],
            ["Generated", generatedAt.formatted(date: .abbreviated, time: .standard)],
            ["Period", periodLabel],
            ["Scope", scope],
            [],
            ["Provider", "Plan", "Window", "Usage", "Source", "Notes"]
        ] + rows.map { row in
            [row.providerName, row.planName, row.windowName, row.percentText, row.source, row.notes]
        }
    }

}

struct SettingsView: View {
    @Binding var displayMode: String
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
                LaunchAtLoginSetting()
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
        let configuredPlanName = settings.planName.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveUsage = settings.dataSource == .localAdapter ? liveUsage : nil
        let livePlanName = liveUsage?.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let livePlanName, !livePlanName.isEmpty {
            planName = livePlanName
        } else {
            planName = configuredPlanName
        }
        symbol = settings.symbolName
        if let liveUsage {
            status = liveUsage.status
            statusColor = liveUsage.statusColor
            windows = liveUsage.windows
        } else if !settings.visibleManualWindows.isEmpty {
            status = "Manual"
            statusColor = .orange
            windows = settings.visibleManualWindows.map(WindowPreview.init(window:))
        } else {
            status = "Unavailable"
            statusColor = .secondary
            windows = [WindowPreview(name: "Usage unavailable", percent: nil,
                                     resetText: settings.canReadLiveUsage
                                         ? "Waiting for provider data"
                                         : "No recorded usage or manual windows")]
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

    func applying(displayMode: DisplayMode, history: [RecordedTokenUsage], now: Date = Date()) -> ProviderPreview {
        guard let range = UsagePeriods.range(displayMode, at: now) else { return self }
        let summary = TokenPeriodSummary.summarize(history, in: range)
        let window = WindowPreview(
            name: "Recorded tokens",
            percent: nil,
            resetText: summary.map { "\($0.count) recorded events · \(displayMode.windowTitle) (UTC)" }
                ?? "No token events recorded in this period",
            valueText: summary.map { $0.tokens.formatted() }
        )
        return ProviderPreview(id: id, name: name, planName: planName, symbol: symbol,
                               status: summary == nil ? "Unavailable" : "Local",
                               statusColor: summary == nil ? .secondary : .green, windows: [window])
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
    let hasKnownPercent: Bool
    let valueText: String?

    var percentText: String {
        valueText ?? (hasKnownPercent ? "\(Int((percent * 100).rounded()))%" : "—")
    }

    init(
        name: String,
        percent: Double?,
        resetText: String,
        displayModes: Set<DisplayMode> = [],
        valueText: String? = nil
    ) {
        self.name = name
        let fraction = percent.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        self.percent = fraction ?? 0
        self.hasKnownPercent = fraction != nil
        self.valueText = valueText
        self.resetText = resetText
        self.displayModes = displayModes
    }

    init(window: ManualUsageWindow) {
        self.init(name: window.label.isEmpty ? window.kind.rawValue : window.label,
                  percent: window.usedPercent / 100,
                  resetText: window.resetNote.isEmpty ? "Manual window" : window.resetNote,
                  displayModes: window.kind.displayModes)
    }

    init(codexWindow: CodexRateLimitWindow, now: Date = Date()) {
        let resetsAt = Date(timeIntervalSince1970: codexWindow.resetsAt)
        let hasReset = resetsAt <= now

        self.init(name: Self.codexWindowName(minutes: codexWindow.windowMinutes),
                  percent: hasReset ? nil : codexWindow.usedPercent / 100,
                  resetText: Self.codexResetText(resetsAt: resetsAt, relativeTo: now),
                  displayModes: Self.codexDisplayModes(minutes: codexWindow.windowMinutes))
    }

    func matches(displayMode: DisplayMode) -> Bool {
        displayModes.contains(displayMode)
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

    static func resetText(
        resetsAt: Date,
        relativeTo now: Date = Date(),
        expiredText: String = "Window reset; waiting for fresh provider data"
    ) -> String {
        let remainingSeconds = Int(resetsAt.timeIntervalSince(now))
        guard remainingSeconds > 0 else {
            return expiredText
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

    private static func codexResetText(resetsAt: Date, relativeTo now: Date) -> String {
        resetText(
            resetsAt: resetsAt,
            relativeTo: now,
            expiredText: "Window reset; waiting for next Codex CLI event"
        )
    }
}

private func recentJSONFiles(in root: URL, descendInto: ((URL) -> Bool)? = nil, matching: (URL) -> Bool) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }

    var files: [(url: URL, modifiedAt: Date)] = []
    for case let file as URL in enumerator {
        if file.hasDirectoryPath, let descendInto, !descendInto(file) {
            enumerator.skipDescendants()
            continue
        }
        guard ["json", "jsonl"].contains(file.pathExtension.lowercased()), matching(file) else {
            continue
        }

        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else {
            continue
        }
        files.append((file, values.contentModificationDate ?? .distantPast))
    }

    return files
        .sorted { $0.modifiedAt > $1.modifiedAt }
        .map(\.url)
}

private func jsonObjects(in file: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: file, options: .mappedIfSafe)
    if file.pathExtension.lowercased() == "json" {
        let object = try JSONSerialization.jsonObject(with: data)
        if let row = object as? [String: Any] { return [row] }
        return object as? [[String: Any]] ?? []
    }
    return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

private func tokenCount(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let count = Int(number.stringValue), count >= 0 else { return nil }
    return count
}

private func numberValue(for keys: [String], in dictionary: [String: Any]) -> Double? {
    for key in keys {
        if let number = dictionary[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            return number.doubleValue
        }
        if let string = dictionary[key] as? String, let value = Double(string), value.isFinite {
            return value
        }
    }
    return nil
}

private func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
    for key in keys {
        if let value = dictionary[key] as? String, !value.isEmpty {
            return value
        }
    }
    return nil
}

private func displayPlanName(from rawValue: String?) -> String? {
    guard let rawValue else {
        return nil
    }

    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty, trimmedValue.count <= 48 else {
        return nil
    }

    let scalarSet = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "_-+"))
    guard trimmedValue.unicodeScalars.allSatisfy({ scalarSet.contains($0) }) else {
        return nil
    }

    if trimmedValue == trimmedValue.lowercased() || trimmedValue.contains("_") || trimmedValue.contains("-") {
        return trimmedValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    return trimmedValue
}

private func planNameValue(in dictionary: [String: Any]) -> String? {
    displayPlanName(
        from: stringValue(
            for: [
                "plan",
                "plan_name",
                "planName",
                "plan_type",
                "planType",
                "subscription",
                "subscription_tier",
                "subscriptionTier",
                "subscriptionType",
                "subscription_type",
                "tier"
            ],
            in: dictionary
        )
    )
}

private func parseFlexibleDate(_ value: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        ?? (try? Date.ISO8601FormatStyle().parse(value))
}

private func relativeTimestamp(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

struct ProviderLiveUsage {
    let status: String
    let statusColor: Color
    let planName: String?
    let windows: [WindowPreview]
    let tokenHistory: [RecordedTokenUsage]

    init(
        status: String,
        statusColor: Color,
        planName: String? = nil,
        windows: [WindowPreview],
        tokenHistory: [RecordedTokenUsage] = []
    ) {
        self.status = status
        self.statusColor = statusColor
        self.planName = planName
        self.windows = windows
        self.tokenHistory = tokenHistory
    }
}

struct ClaudeCodeUsageReader {
    var root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    var fetchAuthPlan: () -> String? = Self.authStatusPlanName

    func readLatestUsage() throws -> ProviderLiveUsage? {
        let captured = root.appendingPathComponent("vibemeasure-weekly.json")
        var snapshot = (try? Data(contentsOf: captured))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if snapshot == nil {
            // Existing user-saved statusline payloads. Never treat tool calls or chat content as account metadata.
            let files = try recentJSONFiles(in: root, descendInto: { directory in
                ["cache", "statusline", "status-line", "usage"].contains(directory.lastPathComponent.lowercased())
            }) { url in
                let name = url.lastPathComponent.lowercased()
                return ["statusline", "status-line", "rate-limit", "rate_limit", "usage"].contains(where: name.contains)
            }
            for file in files where snapshot == nil {
                snapshot = (try? jsonObjects(in: file))?.reversed().first { object in
                    object["rate_limits"] is [String: Any] || object["rateLimits"] is [String: Any]
                }
            }
        }

        let limits = snapshot?["rate_limits"] as? [String: Any] ?? snapshot?["rateLimits"] as? [String: Any] ?? [:]
        var windows = Self.weeklyWindows(from: limits)
        if windows.isEmpty {
            windows.append(WindowPreview(name: "7-Day", percent: nil,
                resetText: "No current weekly quota reported by Claude Code", displayModes: [.oneWeek]))
        }
        let history = try messageUsage()
        if let usage = history.last {
            windows.append(WindowPreview(name: "Latest message tokens", percent: nil,
                resetText: "Last recorded \(relativeTimestamp(usage.timestamp))", valueText: "\(usage.total.formatted()) tokens"))
        }
        let plan = fetchAuthPlan() ?? planNameValue(in: limits) ?? snapshot.flatMap(planNameValue)
        guard snapshot != nil || !history.isEmpty || plan != nil else { return nil }
        return ProviderLiveUsage(status: "Local", statusColor: .green, planName: plan, windows: windows, tokenHistory: history.recordedHistory)
    }

    private static let cache = SessionFileCache<[SessionTokenRecord]>()

    private func messageUsage() throws -> [SessionTokenRecord] {
        let files = try recentJSONFiles(in: root.appendingPathComponent("projects")) { $0.pathExtension == "jsonl" }
        var records: [SessionTokenRecord] = []
        let usageKey = Data(#""usage""#.utf8)
        for file in files {
            let fileRecords = try? Self.cache.contents(of: file) { data in
                var rows: [SessionTokenRecord] = []
                let decoder = JSONDecoder()
                forEachJSONLine(in: data, containing: usageKey) { line in
                    guard let row = try? decoder.decode(ClaudeMessageEnvelope.self, from: line),
                          let record = row.record else { return }
                    rows.append(record)
                }
                return distinctTokenRecords(rows)
            }
            records.append(contentsOf: fileRecords ?? [])
        }
        return distinctTokenRecords(records)
    }

    static func authStatusPlanName() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ProcessInfo.processInfo.environment["PATH"]?.components(separatedBy: ":") ?? []
        let candidates = (paths + [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"])
            .map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
              let result = try? LocalAgentCommand.run(executable: executable, arguments: ["auth", "status"]),
              result.status == 0,
              let data = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              data["loggedIn"] as? Bool != false else { return nil }
        return planNameValue(in: data)
    }

    static func weeklyWindows(from limits: [String: Any], now: Date = Date()) -> [WindowPreview] {
        var windows: [WindowPreview] = []
        var seen: Set<String> = []
        for key in limits.keys.sorted() {
            // Accept model-specific weekly buckets only when the provider actually supplies them.
            let name: String
            switch key {
            case "seven_day", "sevenDay", "7d", "weekly": name = "7-Day"
            case let key where key.hasPrefix("seven_day_"):
                guard let category = displayPlanName(from: String(key.dropFirst("seven_day_".count))) else { continue }
                name = "7-Day · \(category)"
            default: continue
            }
            guard let window = limits[key] as? [String: Any],
                  let percent = numberValue(for: ["used_percentage", "used_percent", "usedPercent", "usage_percent", "usagePercent", "utilization"], in: window),
                  (0...100).contains(percent), !seen.contains(name) else { continue }
            let reset = numberValue(for: ["resets_at", "resetsAt", "reset_at", "resetAt"], in: window)
                .map(Date.init(timeIntervalSince1970:))
                ?? stringValue(for: ["resets_at", "resetsAt"], in: window).flatMap(parseFlexibleDate)
            seen.insert(name)
            windows.append(WindowPreview(name: name, percent: reset.map { $0 <= now } == true ? nil : percent / 100,
                resetText: reset.map { WindowPreview.resetText(resetsAt: $0, relativeTo: now) } ?? "Claude Code weekly usage",
                displayModes: [.oneWeek]))
        }
        return windows
    }
}

private struct ClaudeMessageEnvelope: Decodable {
    let type: String
    let timestamp: String
    let requestId: String?
    let isApiErrorMessage: Bool?
    let message: Message

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Counts
    }

    struct Counts: Decodable {
        let input_tokens: Int
        let output_tokens: Int
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }

    var record: SessionTokenRecord? {
        guard type == "assistant", isApiErrorMessage != true, message.model != "<synthetic>",
              let id = message.id ?? requestId, !id.isEmpty,
              let date = parseFlexibleDate(timestamp) else { return nil }
        let counts = message.usage
        var total = 0
        for count in [counts.input_tokens, counts.output_tokens, counts.cache_creation_input_tokens ?? 0, counts.cache_read_input_tokens ?? 0] {
            let sum = total.addingReportingOverflow(count)
            guard count >= 0, !sum.overflow else { return nil }
            total = sum.partialValue
        }
        guard total > 0 else { return nil }
        return SessionTokenRecord(id: id, timestamp: date, total: total, model: message.model)
    }
}

struct CodexCliUsageReader {
    var root = (ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")).appendingPathComponent("sessions")
    private static let cache = SessionFileCache<CodexSessionScan>()

    func readLatestUsage() throws -> ProviderLiveUsage? {
        var directories = [root]
        if root.lastPathComponent == "sessions" {
            directories.append(root.deletingLastPathComponent().appendingPathComponent("archived_sessions"))
        }
        let files = try directories.flatMap { directory in
            try recentJSONFiles(in: directory) { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
        }
        var quotas: [String: CodexQuotaSample] = [:]
        var plan: (date: Date, name: String)?
        var records: [SessionTokenRecord] = []
        for file in files {
            guard let scan = try? Self.cache.contents(of: file, parse: { Self.scan($0, file: file) }) else { continue }
            records.append(contentsOf: scan.records)
            for (bucket, sample) in scan.quotas where sample.date >= (quotas[bucket]?.date ?? .distantPast) {
                quotas[bucket] = sample
            }
            if let candidate = scan.plan, candidate.date > (plan?.date ?? .distantPast) { plan = candidate }
        }
        var windows: [WindowPreview] = []
        for key in quotas.keys.sorted() {
            guard let sample = quotas[key] else { continue }
            for window in sample.limits.windows {
                if key == "codex" {
                    windows.append(window)
                } else {
                    windows.append(WindowPreview(name: "\(sample.limits.limitName ?? key) · \(window.name)",
                        percent: window.hasKnownPercent ? window.percent : nil, resetText: window.resetText, displayModes: window.displayModes))
                }
            }
        }
        let history = distinctTokenRecords(records)
        if let latest = history.last {
            windows.append(WindowPreview(name: "Latest recorded tokens", percent: nil,
                resetText: "Last recorded \(relativeTimestamp(latest.timestamp))", valueText: "\(latest.total.formatted()) tokens"))
        }
        guard !windows.isEmpty || plan != nil else { return nil }
        return ProviderLiveUsage(status: "Local", statusColor: .green, planName: plan?.name,
            windows: windows, tokenHistory: history.recordedHistory)
    }

    private static func scan(_ data: Data, file: URL) -> CodexSessionScan {
        var scan = CodexSessionScan()
        var sessionID: String?
        var accounted = 0
        var sawCumulative = false
        let decoder = JSONDecoder()
        let eventKey = Data(#""token_count""#.utf8)
        let metaKey = Data(#""session_meta""#.utf8)
        // Distinguish multiple calls within one clock tick, including legacy last-only records.
        var occurrences: [String: Int] = [:]
        forEachJSONLine(in: data) { line in
            if sessionID == nil, line.range(of: metaKey) != nil,
               let meta = try? JSONSerialization.jsonObject(with: line) as? [String: Any], meta["type"] as? String == "session_meta",
               let payload = meta["payload"] as? [String: Any], let id = payload["id"] as? String { sessionID = id }
            guard line.range(of: eventKey) != nil,
                  let event = try? decoder.decode(CodexEventEnvelope.self, from: line), event.payload.type == "token_count",
                  let date = parseFlexibleDate(event.timestamp) else { return }
            if let limits = event.payload.rateLimits {
                let key = limits.limitID ?? "codex"
                if (limits.primary != nil || limits.secondary != nil), date >= (scan.quotas[key]?.date ?? .distantPast) {
                    scan.quotas[key] = CodexQuotaSample(date: date, limits: limits)
                }
                if let name = limits.planName, date >= (scan.plan?.date ?? .distantPast) { scan.plan = (date, name) }
            }
            let last = event.payload.info?.last_token_usage?.total
            let current = event.payload.info?.total_token_usage?.total
            let increment: Int?
            if let current {
                let delta = current - accounted
                if delta == 0 {
                    increment = nil
                } else if let last, !sawCumulative || last == delta || delta < 0 {
                    increment = last
                } else {
                    increment = delta > 0 ? delta : nil
                }
                sawCumulative = true
                accounted = current
            } else {
                increment = last
                if let last {
                    let sum = accounted.addingReportingOverflow(last)
                    guard !sum.overflow else { return }
                    accounted = sum.partialValue
                }
            }
            guard let increment, increment > 0 else { return }
            let base = "\(sessionID ?? file.lastPathComponent)/\(event.timestamp)/\(current ?? increment)"
            let index = occurrences[base, default: 0]
            occurrences[base] = index + 1
            scan.records.append(SessionTokenRecord(id: "\(base)/\(index)", timestamp: date, total: increment))
        }
        return scan
    }
}

private struct CodexQuotaSample: Sendable {
    let date: Date
    let limits: CodexRateLimits
}

private struct CodexSessionScan: Sendable {
    var quotas: [String: CodexQuotaSample] = [:]
    var plan: (date: Date, name: String)?
    var records: [SessionTokenRecord] = []
}

private struct CodexEventEnvelope: Decodable {
    let timestamp: String
    let payload: Payload

    struct Counts: Decodable {
        let total_tokens: Int?
        let input_tokens: Int?
        let output_tokens: Int?

        var total: Int? {
            if let total_tokens { return total_tokens >= 0 ? total_tokens : nil }
            guard input_tokens != nil || output_tokens != nil else { return nil }
            let input = input_tokens ?? 0, output = output_tokens ?? 0
            let sum = input.addingReportingOverflow(output)
            return (input >= 0 && output >= 0 && !sum.overflow) ? sum.partialValue : nil
        }
    }

    struct Info: Decodable {
        let total_token_usage: Counts?
        let last_token_usage: Counts?
    }

    struct Payload: Decodable {
        let type: String
        let info: Info?
        let rateLimits: CodexRateLimits?

        enum CodingKeys: String, CodingKey {
            case type, info
            case rateLimits = "rate_limits"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            info = try? container.decode(Info.self, forKey: .info)
            rateLimits = try? container.decode(CodexRateLimits.self, forKey: .rateLimits)
        }
    }
}

struct CodexRateLimits: Decodable, Sendable {
    let limitID: String?
    let limitName: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limit_id"
        case limitName = "limit_name"
        case primary
        case secondary
        case planType = "plan_type"
    }

    var planName: String? {
        displayPlanName(from: planType)
    }

    var windows: [WindowPreview] {
        windows(relativeTo: Date())
    }

    func windows(relativeTo now: Date) -> [WindowPreview] {
        [primary, secondary]
            .compactMap(\.self)
            .map { WindowPreview(codexWindow: $0, now: now) }
    }
}

struct CodexRateLimitWindow: Decodable, Sendable {
    let resetsAt: TimeInterval
    let usedPercent: Double
    let windowMinutes: Int

    enum CodingKeys: String, CodingKey {
        case resetsAt = "resets_at"
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
    }
}

struct GeminiCliUsageReader {
    var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp")
    private static let cache = SessionFileCache<[SessionTokenRecord]>()

    func readLatestUsage() throws -> ProviderLiveUsage? {
        let files = try recentJSONFiles(in: root) { $0.deletingLastPathComponent().lastPathComponent == "chats" }
        var records: [SessionTokenRecord] = []
        for file in files {
            let jsonLines = file.pathExtension.lowercased() == "jsonl"
            guard let fileRecords = try? Self.cache.contents(of: file, parse: { data in
                var rows: [SessionTokenRecord] = []
                func add(_ item: [String: Any]) {
                    guard let usage = item["tokens"] as? [String: Any], let total = tokenCount(usage["total"]), total > 0,
                          let timestamp = stringValue(for: ["timestamp", "createdAt", "updatedAt"], in: item),
                          let date = parseFlexibleDate(timestamp) else { return }
                    let id = stringValue(for: ["id", "messageId"], in: item) ?? "\(file.deletingPathExtension().lastPathComponent)/\(timestamp)"
                    rows.append(SessionTokenRecord(id: id, timestamp: date, total: total, model: item["model"] as? String))
                }
                if jsonLines {
                    forEachJSONLine(in: data, containing: Data(#""tokens""#.utf8)) { line in
                        if let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { add(row) }
                    }
                } else if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    (object["messages"] as? [[String: Any]] ?? [object]).forEach(add)
                }
                return distinctTokenRecords(rows)
            }) else { continue }
            records.append(contentsOf: fileRecords)
        }
        let history = distinctTokenRecords(records)
        guard let latest = history.last else { return nil }
        let window = WindowPreview(name: latest.model ?? "Latest message tokens", percent: nil,
            resetText: "Last recorded \(relativeTimestamp(latest.timestamp))", valueText: "\(latest.total.formatted()) tokens")
        return ProviderLiveUsage(status: "Local", statusColor: .green, windows: [window], tokenHistory: history.recordedHistory)
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

        let windows = response.windows
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
        let quotaArguments = ["quota", "show", "--output", "json", "--quiet", "--non-interactive"]
        let executable = executableURL(for: command)
        let result = try LocalAgentCommand.run(
            executable: executable ?? URL(fileURLWithPath: "/usr/bin/env"),
            arguments: executable == nil ? [command.isEmpty ? "mmx" : command] + quotaArguments : quotaArguments
        )
        guard result.status == 0 else {
            throw LocalUsageReaderError.commandFailed(
                command: "mmx quota show",
                status: Int(result.status),
                stderr: Self.redactedSecretText(String(decoding: result.stderr.prefix(2_048), as: UTF8.self))
            )
        }
        return result.stdout
    }

    private func executableURL(for command: String) -> URL? {
        let fileManager = FileManager.default
        if command.hasPrefix("/"), fileManager.isExecutableFile(atPath: command) {
            return URL(fileURLWithPath: command)
        }

        guard command.isEmpty || command == "mmx" else { return nil }
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

    var windows: [WindowPreview] {
        modelRemains.flatMap(\.windows) + missingMediaWindows
    }

    private var missingMediaWindows: [WindowPreview] {
        let reportedCategories = Set(modelRemains.map(\.quotaCategory))
        return MiniMaxQuotaCategory.mediaCategories
            .filter { !reportedCategories.contains($0) }
            .flatMap(\.unreportedWindows)
    }
}

struct MiniMaxBaseResponse: Decodable {
    let statusCode: Int
    let statusMsg: String
}

struct MiniMaxModelRemain: Decodable {
    let modelName: String
    let endTime: Int64?
    let remainsTime: Int64?
    let currentIntervalTotalCount: Int?
    let currentIntervalUsageCount: Int?
    let currentIntervalRemainingPercent: Double?
    let currentIntervalStatus: Int?
    let currentWeeklyTotalCount: Int?
    let currentWeeklyUsageCount: Int?
    let weeklyEndTime: Int64?
    let weeklyRemainsTime: Int64?
    let currentWeeklyRemainingPercent: Double?
    let currentWeeklyStatus: Int?

    var quotaCategory: MiniMaxQuotaCategory {
        MiniMaxQuotaCategory(modelName: modelName)
    }

    var windows: [WindowPreview] {
        [
            window(label: "5-Hour", mode: .fiveHours, count: currentIntervalUsageCount,
                   total: currentIntervalTotalCount, remainingPercent: currentIntervalRemainingPercent,
                   status: currentIntervalStatus, duration: remainsTime, end: endTime),
            window(label: "1 Week", mode: .oneWeek, count: currentWeeklyUsageCount,
                   total: currentWeeklyTotalCount, remainingPercent: currentWeeklyRemainingPercent,
                   status: currentWeeklyStatus, duration: weeklyRemainsTime, end: weeklyEndTime)
        ]
    }

    private func window(label: String, mode: DisplayMode, count: Int?, total: Int?,
                        remainingPercent: Double?, status: Int?, duration: Int64?, end: Int64?) -> WindowPreview {
        var percent: Double?
        let detail: String
        let reportedPercent = remainingPercent.flatMap { (0...100).contains($0) ? $0 : nil }
        if status == 3 && total == 0 {
            detail = "Not included in this plan"
        } else if let total, let remaining = Self.remainingCount(count: count, total: total, percent: reportedPercent) {
            let used = total - remaining
            percent = Double(used) / Double(total)
            detail = "\(used)/\(total) used; \(remaining) available"
        } else if let reportedPercent {
            percent = 1 - reportedPercent / 100
            detail = "remaining \(reportedPercent.formatted())%"
        } else {
            detail = "Usage not reported"
        }

        let reset = Self.resetPrefix(remainingMilliseconds: duration, endMilliseconds: end)
        return WindowPreview(
            name: "\(quotaCategory.displayName) \(label)",
            percent: percent,
            resetText: [reset, detail].compactMap { $0 }.joined(separator: "; "),
            displayModes: [mode]
        )
    }

    // mmx treats usage_count as remaining by default. Some responses instead contain
    // the used count; the independently reported remaining percentage disambiguates.
    private static func remainingCount(count: Int?, total: Int, percent: Double?) -> Int? {
        guard let count, total > 0, (0...total).contains(count) else { return nil }
        guard let percent else { return count }
        let directError = abs(100 * Double(count) / Double(total) - percent)
        let inverseError = abs(100 * Double(total - count) / Double(total) - percent)
        guard min(directError, inverseError) <= 1 else { return nil }
        return inverseError < directError ? total - count : count
    }

    private static func resetPrefix(remainingMilliseconds: Int64?, endMilliseconds: Int64?) -> String? {
        if let remainingMilliseconds, remainingMilliseconds > 0 {
            return "Resets in \(durationText(seconds: remainingMilliseconds / 1_000))"
        }
        guard let endMilliseconds, endMilliseconds > 0 else { return nil }
        let endDate = Date(timeIntervalSince1970: TimeInterval(endMilliseconds) / 1_000)
        let remainingSeconds = Int64(endDate.timeIntervalSinceNow)
        guard remainingSeconds > 0 else { return "Reset time passed; refresh MiniMAX" }
        return "Resets in \(durationText(seconds: remainingSeconds))"
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

enum MiniMaxQuotaCategory: Hashable {
    case text
    case video
    case audio
    case music
    case other(String)

    static let mediaCategories: [MiniMaxQuotaCategory] = [.audio, .music]

    init(modelName: String) {
        let normalizedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalizedName.lowercased() {
        case "", "general":
            self = .text
        case "video":
            self = .video
        case "audio", "speech":
            self = .audio
        case "music":
            self = .music
        default:
            self = .other(displayPlanName(from: normalizedName) ?? normalizedName)
        }
    }

    var displayName: String {
        switch self {
        case .text:
            "Text"
        case .video:
            "Video"
        case .audio:
            "Audio"
        case .music:
            "Music"
        case let .other(name):
            name.isEmpty ? "MiniMAX" : name
        }
    }

    var unreportedWindows: [WindowPreview] {
        [
            WindowPreview(
                name: "\(displayName) 5-Hour",
                percent: nil,
                resetText: "Not reported by mmx quota show; no verified usage or available quota",
                displayModes: [.fiveHours]
            ),
            WindowPreview(
                name: "\(displayName) 1 Week",
                percent: nil,
                resetText: "Not reported by mmx quota show; no verified usage or available quota",
                displayModes: [.oneWeek]
            )
        ]
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
                    ForEach(provider.availableDataSources) { source in
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
                if provider.visibleManualWindows.isEmpty {
                    Text("No manual windows configured.")
                        .foregroundStyle(.secondary)
                }

                ForEach($provider.manualWindows) { $window in
                    if provider.allowedWindowKinds.contains(window.kind) {
                        ManualWindowEditor(window: $window, kinds: provider.allowedWindowKinds) {
                            provider.manualWindows.removeAll { $0.id == window.id }
                        }
                    }
                }

                Button {
                    let kind = provider.allowedWindowKinds[0]
                    provider.manualWindows.append(ManualUsageWindow(kind: kind, label: kind.rawValue))
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
    let kinds: [UsageWindowKind]
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Kind", selection: $window.kind) {
                    ForEach(kinds) { kind in
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
    private static let currentStorageVersion = 5

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
        if storedVersion < 5 {
            loadedProviders = Self.providersWithVerifiedAdapterDefaults(loadedProviders)
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
        .builtIn(id: "claude", displayName: "Claude Code", commandHint: "claude", symbolName: "sparkle", dataSource: .localAdapter),
        .builtIn(id: "codex", displayName: "Codex CLI", commandHint: "codex", symbolName: "swirl.circle.righthalf.filled", dataSource: .localAdapter),
        .builtIn(id: "devin-terminal", displayName: "Devin for Terminal", commandHint: "", symbolName: "terminal"),
        .builtIn(id: "gemini", displayName: "Gemini CLI", commandHint: "gemini", symbolName: "diamond", dataSource: .localAdapter),
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

    private static func providersWithVerifiedAdapterDefaults(_ providers: [ProviderSettings]) -> [ProviderSettings] {
        providers.map { provider in
            guard ["claude", "gemini"].contains(provider.id) else {
                return provider
            }

            var migratedProvider = provider
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
        if !availableDataSources.contains(dataSource) {
            dataSource = visibleManualWindows.isEmpty ? .unknown : .manual
        }
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

    var availableDataSources: [ProviderDataSource] {
        hasVerifiedLocalAdapter ? [.localAdapter, .manual, .unknown] : [.manual, .unknown]
    }

    var allowedWindowKinds: [UsageWindowKind] {
        id == "claude" ? [.oneWeek] : UsageWindowKind.allCases
    }

    var visibleManualWindows: [ManualUsageWindow] {
        manualWindows.filter { allowedWindowKinds.contains($0.kind) }
    }

    var hasVerifiedLocalAdapter: Bool {
        ["claude", "codex", "gemini", "minimax"].contains(id)
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
