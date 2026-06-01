import XCTest
import SwiftUI
@testable import VibeMeasureMac

final class UsageWindowTests: XCTestCase {
    func testExpiredCodexWindowResetsDisplayedUsage() {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = CodexRateLimitWindow(
            resetsAt: 999,
            usedPercent: 87,
            windowMinutes: 300
        )

        let preview = WindowPreview(codexWindow: window, now: now)

        XCTAssertEqual(preview.name, "5-Hour")
        XCTAssertEqual(preview.percent, 0)
        XCTAssertEqual(preview.percentText, "0%")
        XCTAssertEqual(preview.resetText, "Window reset; waiting for next Codex CLI event")
        XCTAssertTrue(preview.matches(displayMode: .fiveHours))
    }

    func testActiveCodexWindowKeepsReportedUsage() {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = CodexRateLimitWindow(
            resetsAt: 1_600,
            usedPercent: 42,
            windowMinutes: 300
        )

        let preview = WindowPreview(codexWindow: window, now: now)

        XCTAssertEqual(preview.percent, 0.42, accuracy: 0.001)
        XCTAssertEqual(preview.percentText, "42%")
        XCTAssertEqual(preview.resetText, "Resets in 10m")
    }

    func testCodexPlanTypeDisplaysPlanName() throws {
        let json = """
        {
          "plan_type": "plus",
          "primary": {
            "resets_at": 1600,
            "used_percent": 42,
            "window_minutes": 300
          }
        }
        """

        let rateLimits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))

        XCTAssertEqual(rateLimits.planName, "Plus")
    }

    func testLivePlanOverridesConfiguredPlanInProviderPreview() {
        let settings = ProviderSettings.builtIn(
            id: "codex",
            displayName: "Codex CLI",
            planName: "Manual Plan",
            commandHint: "codex",
            symbolName: "terminal",
            dataSource: .localAdapter
        )
        let liveUsage = ProviderLiveUsage(
            status: "Local",
            statusColor: .green,
            planName: "Plus",
            windows: []
        )

        let preview = ProviderPreview(settings: settings, liveUsage: liveUsage)

        XCTAssertEqual(preview.planName, "Plus")
    }
}
