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

    func testMiniMaxMediaQuotaWindowsShowUsedAndAvailableCounts() throws {
        let json = """
        {
          "model_remains": [
            {
              "start_time": 1780498800000,
              "end_time": 1780516800000,
              "remains_time": 300000,
              "current_interval_total_count": 3,
              "current_interval_usage_count": 1,
              "model_name": "video",
              "current_weekly_total_count": 21,
              "current_weekly_usage_count": 5,
              "weekly_start_time": 1780272000000,
              "weekly_end_time": 1780876800000,
              "weekly_remains_time": 600000,
              "current_interval_status": 1,
              "current_interval_remaining_percent": 66,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 76
            },
            {
              "start_time": 1780498800000,
              "end_time": 1780516800000,
              "remains_time": 300000,
              "current_interval_total_count": 10,
              "current_interval_usage_count": 2,
              "model_name": "audio",
              "current_weekly_total_count": 50,
              "current_weekly_usage_count": 12,
              "weekly_start_time": 1780272000000,
              "weekly_end_time": 1780876800000,
              "weekly_remains_time": 600000,
              "current_interval_status": 1,
              "current_interval_remaining_percent": 80,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 76
            },
            {
              "start_time": 1780498800000,
              "end_time": 1780516800000,
              "remains_time": 300000,
              "current_interval_total_count": 4,
              "current_interval_usage_count": 0,
              "model_name": "music",
              "current_weekly_total_count": 28,
              "current_weekly_usage_count": 3,
              "weekly_start_time": 1780272000000,
              "weekly_end_time": 1780876800000,
              "weekly_remains_time": 600000,
              "current_interval_status": 1,
              "current_interval_remaining_percent": 100,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 89
            }
          ],
          "base_resp": {
            "status_code": 0,
            "status_msg": "success"
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(MiniMaxQuotaResponse.self, from: Data(json.utf8))
        let windows = response.windows

        XCTAssertEqual(windows.map(\.name), [
            "Video 5-Hour",
            "Video 1 Week",
            "Audio 5-Hour",
            "Audio 1 Week",
            "Music 5-Hour",
            "Music 1 Week"
        ])
        XCTAssertEqual(windows[0].resetText, "Resets in 5m; 1/3 used; 2 available")
        XCTAssertEqual(windows[1].resetText, "Resets in 10m; 5/21 used; 16 available")
        XCTAssertEqual(windows[2].resetText, "Resets in 5m; 2/10 used; 8 available")
        XCTAssertEqual(windows[5].resetText, "Resets in 10m; 3/28 used; 25 available")
    }
}
