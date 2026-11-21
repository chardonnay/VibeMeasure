import XCTest
@testable import VibeMeasureMac

final class AgentReaderTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testClaudeWeeklyBucketsAndTranscriptCountersStaySeparate() throws {
        let root = try directory()
        try write(#"{"rate_limits":{"five_hour":{"used_percentage":80},"seven_day":{"used_percentage":41},"seven_day_sonnet":{"used_percentage":5},"seven_day_opus":{},"monthly":{"used_percentage":90}}}"#,
                  to: "vibemeasure-weekly.json", in: root)
        let first = #"{"type":"assistant","timestamp":"2026-11-21T10:00:00Z","message":{"id":"msg_1","usage":{"input_tokens":7,"output_tokens":1}}}"#
        let final = #"{"type":"assistant","timestamp":"2026-11-21T10:00:01Z","message":{"id":"msg_1","usage":{"input_tokens":7,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":5}}}"#
        try write([first, final].joined(separator: "\n"), to: "projects/repo/a.jsonl", in: root)
        try write(final, to: "projects/repo/b.jsonl", in: root)
        let reader = ClaudeCodeUsageReader(root: root, fetchAuthPlan: { "Test tier" })
        let result = try XCTUnwrap(reader.readLatestUsage())
        XCTAssertEqual(result.planName, "Test tier")
        XCTAssertEqual(result.windows.map(\.name), ["7-Day", "7-Day · Sonnet", "Latest message tokens"])
        XCTAssertEqual(result.windows[0].percent, 0.41, accuracy: 0.001)
        XCTAssertFalse(result.windows[2].hasKnownPercent)
        XCTAssertEqual(result.tokenHistory.map(\.tokens), [17])
    }

    func testClaudeIgnoresNonWeeklyLimitsAndExpiredPercent() throws {
        let root = try directory()
        try write(#"{"rate_limits":{"five_hour":{"used_percentage":81},"monthly":{"used_percentage":9},"seven_day":{"used_percentage":50,"resets_at":1}}}"#,
                  to: "statusline.json", in: root)
        let result = try XCTUnwrap(ClaudeCodeUsageReader(root: root, fetchAuthPlan: { nil }).readLatestUsage())
        XCTAssertEqual(result.windows.map(\.name), ["7-Day"])
        XCTAssertFalse(result.windows[0].hasKnownPercent)
    }

    func testGeminiLegacyAndStreamingRecordsDeduplicateAndRereadAppends() throws {
        let root = try directory()
        let first = #"{"id":"first","timestamp":"2026-11-20T00:00:00Z","model":"example","tokens":{"total":9}}"#
        let second = #"{"id":"second","timestamp":"2026-11-21T00:00:00Z","model":"example","tokens":{"total":11}}"#
        try write("{\n\"messages\":[\n\(first)\n]\n}", to: "repo/chats/session.json", in: root)
        try write([first, second].joined(separator: "\n"), to: "repo/chats/another.jsonl", in: root)
        let reader = GeminiCliUsageReader(root: root)
        let result = try XCTUnwrap(reader.readLatestUsage())
        XCTAssertEqual(result.tokenHistory.map(\.tokens), [9, 11])
        XCTAssertFalse(result.windows[0].hasKnownPercent)
        try write(first, to: "repo/chats/another.jsonl", in: root)
        XCTAssertEqual(try reader.readLatestUsage()?.tokenHistory.map(\.tokens), [9])
    }

    func testCodexRetainsQuotaAlongsideTokenOnlyAndRepeatedSnapshots() throws {
        let root = try directory()
        let lines = [
            #"{"type":"session_meta","payload":{"id":"s"}}"#,
            #"{"timestamp":"2026-11-21T10:00:00Z","payload":{"type":"token_count","info":null,"rate_limits":{"plan_type":"pro","primary":{"window_minutes":10080,"used_percent":14,"resets_at":3000000000}}}}"#,
            #"{"timestamp":"2026-11-21T10:00:01Z","payload":{"type":"token_count","rate_limits":null,"info":{"last_token_usage":{"input_tokens":8,"cached_input_tokens":2,"output_tokens":2,"reasoning_output_tokens":1},"total_token_usage":{"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-11-21T10:00:02Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10},"total_token_usage":{"total_tokens":100}}}}"#,
            #"{"timestamp":"2026-11-21T10:00:03Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":2}}}}"#,
            #"{"timestamp":"2026-11-21T10:00:04Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":107}}}}"#
        ].joined(separator: "\n")
        try write(lines, to: "sessions/year/rollout-example.jsonl", in: root)
        try write(lines, to: "archived_sessions/rollout-copy.jsonl", in: root)
        let archived = #"{"timestamp":"2026-11-21T11:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":7}}}}"#
        try write(archived, to: "archived_sessions/rollout-archive-only.jsonl", in: root)
        let result = try XCTUnwrap(CodexCliUsageReader(root: root.appendingPathComponent("sessions")).readLatestUsage())
        XCTAssertEqual(result.planName, "Pro")
        XCTAssertEqual(result.windows.first?.percentText, "14%")
        XCTAssertFalse(try XCTUnwrap(result.windows.last).hasKnownPercent)
        XCTAssertEqual(result.tokenHistory.map(\.tokens), [10, 2, 5, 7])
    }
}
