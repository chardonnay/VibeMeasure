import Foundation
import PDFKit
import SQLite3
import XCTest
@testable import VibeMeasureMac

final class HistoryAndSourceTests: XCTestCase {
    @MainActor
    func testPegelbotLoadsAsAMenuBarTemplate() throws {
        let icon = StatusIcon.image
        XCTAssertEqual(icon.size, CGSize(width: 18, height: 18))
        XCTAssertTrue(icon.isTemplate)
        XCTAssertNotNil(icon.tiffRepresentation)
    }

    @MainActor
    func testBrandMarksLoadForBothAppearances() {
        let ids = ["claude", "codex", "devin-terminal", "gemini", "opencode", "hermes", "kimi-cli",
                   "cursor-agent", "qwen-code", "qoder-cli", "github-copilot-cli", "kiro-cli",
                   "mistral-vibe-cli", "deepseek-tui", "minimax", "antigravity", "cline", "amp", "openhands"]
        for id in ids {
            XCTAssertNotNil(ProviderMark.logo(for: id, dark: false), id)
            XCTAssertNotNil(ProviderMark.logo(for: id, dark: true), id)
        }
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    func testReportedWeekIsAnISOUTCWeekIndependentOfProviderReset() throws {
        let now = try date("2026-11-21T12:00:00Z")
        let start = try date("2026-11-16T00:00:00Z")
        let end = try date("2026-11-23T00:00:00Z")
        let events = [
            RecordedTokenUsage(occurredAt: start.addingTimeInterval(-1), tokens: 1024),
            RecordedTokenUsage(occurredAt: start, tokens: 9),
            RecordedTokenUsage(occurredAt: end, tokens: 2048)
        ]
        let settings = ProviderSettings.builtIn(id: "claude", displayName: "Claude Code", commandHint: "claude",
                                               symbolName: "terminal", dataSource: .localAdapter)
        let live = ProviderLiveUsage(status: "Local", statusColor: .green, windows: [
            WindowPreview(name: "Weekly quota", percent: 0.93, resetText: "Wednesday", displayModes: [.oneWeek])
        ])
        let preview = ProviderPreview(settings: settings, liveUsage: live)
        let comparison = preview.applying(displayMode: .oneWeek, history: events, now: now)
        XCTAssertEqual(UsagePeriods.range(.oneWeek, at: now), start..<end)
        XCTAssertEqual(comparison.windows.first?.percentText, "9")
        XCTAssertEqual(comparison.windows.first?.hasKnownPercent, false)
        XCTAssertEqual(preview.windows.first?.percentText, "93%")
    }

    func testManualClaudeOnlyShowsWeeklyWindowsAndNeverReportsAPIProvenance() throws {
        var claude = ProviderSettings.builtIn(id: "claude", displayName: "Claude Code",
                                            commandHint: "claude", symbolName: "terminal", dataSource: .officialAPI)
        claude.manualWindows = [
            ManualUsageWindow(kind: .fiveHours, label: "Legacy 5h", usedPercent: 99),
            ManualUsageWindow(kind: .oneWeek, label: "Weekly", usedPercent: 66)
        ]
        claude.isEnabled = true
        let migrated = try JSONDecoder().decode(ProviderSettings.self, from: JSONEncoder().encode(claude))
        XCTAssertEqual(migrated.dataSource, .manual)
        XCTAssertEqual(migrated.allowedWindowKinds, [.oneWeek])
        let preview = ProviderPreview(settings: migrated)
        XCTAssertEqual(preview.reportRows().map(\.source), ["Manual"])
        XCTAssertEqual(preview.reportRows().map(\.percentText), ["66%"])
        var disabled = migrated
        disabled.isEnabled = false
        XCTAssertEqual(WidgetSnapshotWriter.snapshot(providers: [disabled], readings: [:]).providers.count, 0)
        XCTAssertEqual(WidgetSnapshotWriter.snapshot(providers: [migrated], readings: [:]).providers.first?.rows,
                       ["Weekly · 66%"])
    }

    func testCustomReportQueriesDatabaseAcrossWholeUTCDays() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let sql = """
            CREATE TABLE usage_events(tool_id TEXT, occurred_at TEXT, total_tokens INTEGER);
            INSERT INTO usage_events VALUES ('codex', '2026-11-20T23:59:59.999999+00:00', 512),
            ('codex', '2026-11-21T00:00:00+00:00', 4), ('codex', '2026-11-21T23:59:59.999999+00:00', 13),
            ('codex', '2026-11-22T00:00:00+00:00', 256);
            """
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
        let day = try date("2026-11-21T12:00:00Z")
        let range = try XCTUnwrap(UsagePeriods.range(.custom, at: day, from: day, through: day))
        let query = ImportedUsageQuery(url: url, range: range)
        XCTAssertEqual(try query.read()["codex"], TokenPeriodSummary(tokens: 17, count: 2))
        XCTAssertEqual(sqlite3_exec(connection, "CREATE VIEW reportable_usage_events AS SELECT * FROM usage_events WHERE total_tokens != 13",
                                    nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try query.read()["codex"], TokenPeriodSummary(tokens: 4, count: 1))
        XCTAssertNil(UsagePeriods.range(.custom, at: day, from: day.addingTimeInterval(86400), through: day))
    }

    func testMissingHistoryAndMissingQuotaRemainUnknown() {
        let settings = ProviderSettings.customTemplate(id: "custom")
        let preview = ProviderPreview(settings: settings)
        XCTAssertEqual(preview.windows.first?.percentText, "—")
        XCTAssertEqual(preview.applying(displayMode: .fiveHours, history: []).windows.first?.percentText, "—")
        XCTAssertEqual(WindowPreview(name: "Known zero", percent: 0, resetText: "").percentText, "0%")
    }

    func testHistoricalExportsPreserveRecordedUsageAndExistingDestinationOnError() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = SnapshotReport(periodLabel: "2026-11-21 UTC", generatedAt: try date("2026-11-21T12:00:00Z"),
                                    rows: [ReportSnapshotRow(providerName: "Codex", planName: "—", windowName: "Tokens",
                                                             percentText: "4321", source: "SQLite", notes: "3 events")],
                                    isSnapshot: false)
        let xlsx = folder.appendingPathComponent("history.xlsx")
        try Data("previous export".utf8).write(to: xlsx)
        try SnapshotReportExporter.write(report, format: .xlsx, to: xlsx)
        let sheet = try LocalAgentCommand.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                                              arguments: ["-p", xlsx.path, "xl/worksheets/sheet1.xml"])
        XCTAssertEqual(sheet.status, 0)
        let xml = String(decoding: sheet.stdout, as: UTF8.self)
        XCTAssertTrue(xml.contains("4321"))
        XCTAssertTrue(xml.contains(report.scope))

        let pdf = folder.appendingPathComponent("history.pdf")
        try SnapshotReportExporter.write(report, format: .pdf, to: pdf)
        let contents = try XCTUnwrap(PDFDocument(url: pdf)?.string)
        XCTAssertTrue(contents.contains("4321"))
        XCTAssertTrue(contents.contains("Codex"))

        let inUse = folder.appendingPathComponent("destination.xlsx", isDirectory: true)
        try FileManager.default.createDirectory(at: inUse, withIntermediateDirectories: true)
        let existing = inUse.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: existing)
        XCTAssertThrowsError(try SnapshotReportExporter.write(report, format: .xlsx, to: inUse))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
    }
}
