import Foundation
import XCTest
@testable import VibeMeasureMac

final class RefreshAndQuotaTests: XCTestCase {
    func testCommandDrainsBothStreamsBeforeExit() throws {
        let result = try LocalAgentCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/head -c 250000 /dev/zero >&2; /usr/bin/head -c 250000 /dev/zero; exit 7"]
        )
        XCTAssertEqual(result.stdout.count, 250_000)
        XCTAssertEqual(result.stderr.count, 250_000)
        XCTAssertEqual(result.status, 7)
    }

    func testUnresponsiveCommandTimesOut() {
        let start = Date()
        XCTAssertThrowsError(try LocalAgentCommand.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], timeout: 0.2
        )) { error in
            guard case LocalAgentCommandError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    @MainActor
    func testRefreshReturnsImmediatelyAndDisablingDiscardsTheResult() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let command = folder.appendingPathComponent("quota-test")
        let result = #"{"base_resp":{"status_code":0,"status_msg":"ok"},"model_remains":[{"model_name":"video","current_interval_total_count":3,"current_interval_usage_count":2}]}"#
        try """
        #!/bin/sh
        while [ ! -f "$0.release" ]; do /bin/sleep 0.05; done
        echo '\(result)'
        touch "$0.done"
        """.write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        var provider = ProviderSettings.builtIn(id: "minimax", displayName: "Test",
                                              commandHint: command.path, symbolName: "terminal", dataSource: .localAdapter)
        provider.isEnabled = true
        let store = UsageRefreshStore()
        store.pullNow(providers: [provider])
        XCTAssertTrue(store.isRefreshing)
        provider.isEnabled = false
        store.configure(providers: [provider])
        XCTAssertFalse(store.isRefreshing)
        try Data().write(to: command.appendingPathExtension("release"))
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: command.appendingPathExtension("done").path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: command.appendingPathExtension("done").path))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.lastPulledAtByProvider[provider.id])
        XCTAssertNil(store.liveUsageByProvider[provider.id])
        XCTAssertNil(store.refreshError)
    }

    func testMiniMaxReconcilesCountAgainstRemainingPercentAndKeepsUnknowns() throws {
        let json = """
        {"model_remains":[
          {"model_name":"video","current_interval_total_count":10,"current_interval_usage_count":8,"current_interval_remaining_percent":80,
           "current_weekly_total_count":50,"current_weekly_usage_count":5,"current_weekly_remaining_percent":90},
          {"model_name":"general","current_interval_total_count":500,"current_interval_usage_count":450,
           "current_weekly_total_count":50,"current_weekly_usage_count":10,"current_weekly_remaining_percent":35}
        ],"base_resp":{"status_code":0,"status_msg":"ok"}}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let windows = try decoder.decode(MiniMaxQuotaResponse.self, from: Data(json.utf8)).windows
        XCTAssertEqual(windows[0].resetText, "2/10 used; 8 available")
        XCTAssertEqual(windows[1].resetText, "5/50 used; 45 available")
        XCTAssertEqual(windows[2].resetText, "50/500 used; 450 available")
        XCTAssertEqual(windows[3].resetText, "remaining 35%")
        XCTAssertEqual(windows[4].percentText, "—")
    }
}
