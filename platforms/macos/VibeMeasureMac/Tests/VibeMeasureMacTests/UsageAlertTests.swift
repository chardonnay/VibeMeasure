import Foundation
import XCTest
@testable import VibeMeasureMac

final class UsageAlertTests: XCTestCase {
    func testExpiryUsesLocalCalendarDayAndOnlyFiresOnce() throws {
        let today = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 22)))
        var rule = ProviderAlertRule()
        rule.expiryEnabled = true
        rule.endDay = DateComponents(year: 2026, month: 3, day: 30)
        var receipts: [String: String] = [:]
        rule.daysBefore = 0
        XCTAssertTrue(rule.evaluate(name: "Test", windows: [], now: today, receipts: &receipts).isEmpty)
        rule.daysBefore = 1
        XCTAssertEqual(rule.evaluate(name: "Test", windows: [], now: today, receipts: &receipts).count, 1)
        XCTAssertTrue(rule.evaluate(name: "Test", windows: [], now: today, receipts: &receipts).isEmpty)
        rule.endDay = DateComponents(year: 2026, month: 3, day: 28)
        XCTAssertTrue(rule.evaluate(name: "Test", windows: [], now: today, receipts: &receipts).isEmpty)
    }

    func testUsageAlertsActivateTheLocalReaderForHiddenProviders() {
        var provider = ProviderSettings.builtIn(id: "codex", displayName: "Codex", commandHint: "codex",
                                                symbolName: "terminal", dataSource: .localAdapter)
        XCTAssertFalse(provider.canReadLiveUsage)
        provider.alerts.expiryEnabled = true
        XCTAssertFalse(provider.canReadLiveUsage)
        provider.alerts.usageEnabled = true
        XCTAssertTrue(provider.canReadLiveUsage)
        XCTAssertFalse(provider.isEnabled)
    }

    func testQuotaBoundariesResetsAndMissingReadings() {
        var rule = ProviderAlertRule()
        rule.usageEnabled = true
        var receipts: [String: String] = [:]
        let now = Date()
        func count(_ percent: Double?, _ reset: Date? = nil) -> Int {
            let window = WindowPreview(name: "Quota", percent: percent, resetText: "", resetsAt: reset)
            return rule.evaluate(name: "Test", windows: [window], now: now, receipts: &receipts).count
        }
        XCTAssertEqual(count(0.8999), 0)
        XCTAssertEqual(count(0.90), 1)
        XCTAssertEqual(count(nil), 0)
        XCTAssertEqual(count(1), 0)
        XCTAssertEqual(count(0.1), 0)
        XCTAssertEqual(count(1), 1)
        XCTAssertEqual(count(1, now), 0)
        XCTAssertEqual(count(1, now.addingTimeInterval(600)), 1)
        XCTAssertEqual(count(1, now.addingTimeInterval(600)), 0)
        XCTAssertEqual(count(1, now.addingTimeInterval(1200)), 1)
    }
}
