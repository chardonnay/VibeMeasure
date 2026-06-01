import XCTest
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
}
