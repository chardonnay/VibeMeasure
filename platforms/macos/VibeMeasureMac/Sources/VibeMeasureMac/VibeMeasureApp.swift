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
    @AppStorage("launchAtLogin") private var launchAtLogin = false
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
    private var pendingRefresh = false
    private var pendingForcedRefresh = false

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
        self.providers = providers

        let liveProviderIDs = Set(providers.filter(\.canReadLiveUsage).map(\.id))
        liveUsageByProvider = liveUsageByProvider.filter { liveProviderIDs.contains($0.key) }
        lastPulledAtByProvider = lastPulledAtByProvider.filter { liveProviderIDs.contains($0.key) }
        errorsByProvider = errorsByProvider.filter { liveProviderIDs.contains($0.key) }
        updateRefreshError()
    }

    private func pullDueProviders(force: Bool = false, now: Date = Date()) {
        if isRefreshing {
            pendingRefresh = true
            pendingForcedRefresh = pendingForcedRefresh || force
            return
        }

        let dueProviders = providers.filter { provider in
            shouldPull(provider: provider, now: now, force: force)
        }
        guard !dueProviders.isEmpty else {
            return
        }

        isRefreshing = true
        for provider in dueProviders {
            pull(provider: provider, now: now)
        }
        isRefreshing = false
        updateRefreshError()

        if pendingRefresh {
            let shouldForce = pendingForcedRefresh
            pendingRefresh = false
            pendingForcedRefresh = false
            pullDueProviders(force: shouldForce, now: Date())
        }
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
                errorsByProvider[provider.id] = "No live usage data found for \(provider.displayName)."
            }
            lastPulledAtByProvider[provider.id] = now
        } catch {
            liveUsageByProvider.removeValue(forKey: provider.id)
            errorsByProvider[provider.id] = "\(provider.displayName) live usage could not be read: \(error.localizedDescription)"
            lastPulledAtByProvider[provider.id] = now
        }
    }

    private func readUsage(for provider: ProviderSettings) throws -> ProviderLiveUsage? {
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
                    ProgressView(value: window.percent)
                        .tint(.green)
                    Text(window.resetText)
                        .font(.callout)
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

    var fileNameComponent: String {
        switch self {
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
    @State private var period = ReportPeriod.currentWeek
    @State private var customStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEndDate = Date()
    @State private var exportStatus: String?
    @State private var exportError: String?

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
            Text("Exports contain the current snapshot. Historical aggregation starts after SQLite event persistence is connected.")
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
            rows: rows
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
    var usageFraction: Double {
        let rawValue = percentText.replacingOccurrences(of: "%", with: "")
        return min(max((Double(rawValue) ?? 0) / 100, 0), 1)
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
}

private extension SnapshotReport {
    var averageUsagePercentText: String {
        guard !rows.isEmpty else {
            return "0%"
        }

        let average = rows.map(\.usageFraction).reduce(0, +) / Double(rows.count)
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

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = temporaryRoot
        process.arguments = ["-q", "-r", url.path, "."]
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "zip exited with code \(process.terminationStatus)"
            throw ReportExportError.zipFailed(stderr)
        }
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
        drawFooter(pageNumber: pageNumber)
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
            "\(report.periodLabel) | Snapshot export",
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
        let averageUsage = report.averageUsagePercentText
        let cards = [
            ("Providers", "\(Set(report.rows.map(\.providerName)).count)", "Enabled in report"),
            ("Windows", "\(report.rows.count)", "Visible usage windows"),
            ("Avg. Usage", averageUsage, "Snapshot only")
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
        let barRect = CGRect(x: rect.minX, y: rect.minY + 1, width: 44, height: 8)
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        roundedRect(x: barRect.minX, y: barRect.minY, width: barRect.width, height: barRect.height, radius: 4).fill()

        let fillWidth = barRect.width * CGFloat(row.usageFraction)
        NSColor(calibratedRed: 0.15, green: 0.82, blue: 0.39, alpha: 1).setFill()
        roundedRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height, radius: 4).fill()

        drawText(
            row.percentText,
            in: CGRect(x: rect.minX + 50, y: rect.minY - 1, width: rect.width - 50, height: 14),
            font: .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
            color: NSColor(calibratedWhite: 0.18, alpha: 1)
        )
    }

    private static func drawFooter(pageNumber: Int) {
        NSColor(calibratedWhite: 0.84, alpha: 1).setStroke()
        NSBezierPath.strokeLine(
            from: CGPoint(x: margin, y: margin - 2),
            to: CGPoint(x: pageSize.width - margin, y: margin - 2)
        )
        drawText(
            "Snapshot export. Historical aggregation begins after SQLite event persistence is connected.",
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
            ["Scope", "Latest snapshot export. Historical aggregation starts after SQLite event persistence is connected."],
            [],
            ["Provider", "Plan", "Window", "Usage", "Source", "Notes"]
        ] + rows.map { row in
            [row.providerName, row.planName, row.windowName, row.percentText, row.source, row.notes]
        }
    }

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
        let configuredPlanName = settings.planName.trimmingCharacters(in: .whitespacesAndNewlines)
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

    init(codexWindow: CodexRateLimitWindow, now: Date = Date()) {
        let resetsAt = Date(timeIntervalSince1970: codexWindow.resetsAt)
        let hasReset = resetsAt <= now

        name = Self.codexWindowName(minutes: codexWindow.windowMinutes)
        percent = hasReset ? 0 : min(max(codexWindow.usedPercent / 100, 0), 1)
        resetText = Self.codexResetText(resetsAt: resetsAt, relativeTo: now)
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

private func recentJSONFiles(in root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }

    var files: [(url: URL, modifiedAt: Date)] = []
    for case let file as URL in enumerator {
        guard ["json", "jsonl"].contains(file.pathExtension.lowercased()) else {
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

private func jsonObjects(in file: URL) throws -> [Any] {
    let content = try String(contentsOf: file, encoding: .utf8)
    let lineObjects = content.split(separator: "\n").compactMap { line -> Any? in
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    if !lineObjects.isEmpty {
        return lineObjects
    }

    guard let data = content.data(using: .utf8) else {
        return []
    }
    return [(try JSONSerialization.jsonObject(with: data))]
}

private func numberValue(for keys: [String], in dictionary: [String: Any]) -> Double? {
    for key in keys {
        if let number = dictionary[key] as? NSNumber {
            return number.doubleValue
        }
        if let string = dictionary[key] as? String, let value = Double(string) {
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
                "tier"
            ],
            in: dictionary
        )
    )
}

private func findPlanName(in value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
        if let planName = planNameValue(in: dictionary) {
            return planName
        }

        for nestedValue in dictionary.values {
            if let planName = findPlanName(in: nestedValue) {
                return planName
            }
        }
    }

    if let array = value as? [Any] {
        for nestedValue in array {
            if let planName = findPlanName(in: nestedValue) {
                return planName
            }
        }
    }

    return nil
}

private func parseFlexibleDate(_ value: String) -> Date? {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: value) {
        return date
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
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

    init(
        status: String,
        statusColor: Color,
        planName: String? = nil,
        windows: [WindowPreview]
    ) {
        self.status = status
        self.statusColor = statusColor
        self.planName = planName
        self.windows = windows
    }
}

struct ClaudeCodeUsageReader {
    func readLatestUsage() throws -> ProviderLiveUsage? {
        let claudeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")

        var discoveredPlanName: String?

        if FileManager.default.fileExists(atPath: claudeRoot.path) {
            for file in try recentJSONFiles(in: claudeRoot).prefix(120) {
                for object in try jsonObjects(in: file).reversed() {
                    discoveredPlanName = discoveredPlanName ?? Self.directPlanName(in: object)

                    if let rateLimits = Self.findRateLimits(in: object) {
                        discoveredPlanName = discoveredPlanName ?? planNameValue(in: rateLimits)
                        guard let windows = Self.windows(from: rateLimits), !windows.isEmpty else {
                            continue
                        }
                        let planName = planNameValue(in: rateLimits)
                            ?? discoveredPlanName
                            ?? Self.authStatusPlanName()
                        return ProviderLiveUsage(
                            status: "Local",
                            statusColor: .green,
                            planName: planName,
                            windows: windows
                        )
                    }
                }
            }
        }

        if let planName = discoveredPlanName ?? Self.authStatusPlanName() {
            return ProviderLiveUsage(
                status: "Local",
                statusColor: .green,
                planName: planName,
                windows: [
                    WindowPreview(
                        name: "Usage unavailable",
                        percent: 0,
                        resetText: "No verified Claude Code rate-limit window found"
                    )
                ]
            )
        }

        return nil
    }

    private static func authStatusPlanName() -> String? {
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "auth", "status"]
        process.standardOutput = standardOutput
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: outputData) else {
            return nil
        }
        return findPlanName(in: object)
    }

    private static func directPlanName(in value: Any) -> String? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        return planNameValue(in: dictionary)
    }

    private static func findRateLimits(in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let rateLimits = dictionary["rate_limits"] as? [String: Any] {
                return rateLimits
            }
            if let rateLimits = dictionary["rateLimits"] as? [String: Any] {
                return rateLimits
            }

            for nestedValue in dictionary.values {
                if let found = findRateLimits(in: nestedValue) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for nestedValue in array {
                if let found = findRateLimits(in: nestedValue) {
                    return found
                }
            }
        }

        return nil
    }

    private static func windows(from rateLimits: [String: Any]) -> [WindowPreview]? {
        let candidates: [(keys: [String], fallbackName: String, mode: DisplayMode)] = [
            (["five_hour", "fiveHour", "5h", "five_hours"], "5-Hour", .fiveHours),
            (["seven_day", "sevenDay", "7d", "weekly"], "7-Day", .oneWeek),
            (["monthly", "month", "one_month"], "1 Month", .oneMonth)
        ]

        return candidates.compactMap { candidate in
            guard let window = candidate.keys.compactMap({ rateLimits[$0] as? [String: Any] }).first else {
                return nil
            }

            let usedPercent = numberValue(for: ["used_percentage", "usedPercent", "usage_percent", "usagePercent"], in: window)
                ?? numberValue(for: ["used_percent", "usedPercent"], in: window)
                ?? 0
            let resetsAt = numberValue(for: ["resets_at", "resetsAt", "reset_at", "resetAt"], in: window)
            let resetText = resetsAt.map { WindowPreview.resetText(resetsAt: Date(timeIntervalSince1970: $0)) }
                ?? "Claude Code statusline window"

            return WindowPreview(
                name: stringValue(for: ["name", "label"], in: window) ?? candidate.fallbackName,
                percent: min(max(usedPercent / 100, 0), 1),
                resetText: resetText,
                displayModes: [candidate.mode]
            )
        }
    }
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
                planName: latestEvent.rateLimits.planName,
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
            planName: latestEvent.rateLimits.planName,
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
    let planType: String?

    enum CodingKeys: String, CodingKey {
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

struct GeminiCliUsageReader {
    func readLatestUsage() throws -> ProviderLiveUsage? {
        let geminiRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini")
            .appendingPathComponent("tmp")

        guard FileManager.default.fileExists(atPath: geminiRoot.path) else {
            return nil
        }

        var latestEvent: GeminiTokenEvent?
        for file in try Self.chatSessionFiles(in: geminiRoot).prefix(120) {
            for object in try jsonObjects(in: file) {
                guard let event = GeminiTokenEvent(object: object) else {
                    continue
                }
                if latestEvent == nil || event.timestamp > latestEvent!.timestamp {
                    latestEvent = event
                }
            }
        }

        guard let latestEvent else {
            return nil
        }

        return ProviderLiveUsage(
            status: "Local",
            statusColor: .green,
            windows: [
                WindowPreview(
                    name: latestEvent.model.isEmpty ? "Token usage" : latestEvent.model,
                    percent: 0,
                    resetText: "Latest Gemini CLI event: \(relativeTimestamp(latestEvent.timestamp)); total tokens \(latestEvent.totalTokens)"
                )
            ]
        )
    }

    private static func chatSessionFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let file as URL in enumerator {
            guard ["json", "jsonl"].contains(file.pathExtension.lowercased()),
                  file.deletingLastPathComponent().lastPathComponent == "chats" else {
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
}

struct GeminiTokenEvent {
    let timestamp: Date
    let model: String
    let totalTokens: Int

    init?(object: Any) {
        guard let dictionary = object as? [String: Any],
              let tokenDictionary = dictionary["tokens"] as? [String: Any] else {
            return nil
        }

        let timestamp = stringValue(for: ["timestamp", "createdAt", "updatedAt"], in: dictionary)
            .flatMap(parseFlexibleDate)
            ?? Date.distantPast
        let model = stringValue(for: ["model"], in: dictionary) ?? ""
        let totalTokens = Int(numberValue(for: ["total"], in: tokenDictionary) ?? 0)

        guard totalTokens > 0 else {
            return nil
        }

        self.timestamp = timestamp
        self.model = model
        self.totalTokens = totalTokens
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

    var windows: [WindowPreview] {
        modelRemains.flatMap(\.windows)
    }
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
        switch modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "":
            "MiniMAX"
        case "general":
            "Text"
        case "video":
            "Video"
        case "audio", "speech":
            "Audio"
        case "music":
            "Music"
        default:
            displayPlanName(from: modelName) ?? modelName
        }
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
            let availableCount = max(totalCount - usageCount, 0)
            return "\(resetPrefix); \(usageCount)/\(totalCount) used; \(availableCount) available"
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
