import Foundation
import XCTest
@testable import VibeMeasureMac

final class AdditionalProviderUsageTests: XCTestCase {
    func testAntigravityKeepsCurrentTokensAndExpiresQuota() throws {
        let fixture = """
            {"product":"antigravity","captured_at":"2026-11-21T20:00:00Z",
             "context_window":{"total_input_tokens":70,"total_output_tokens":20},
             "cost":{"total_usd":2.55},"quota":{"fast":{"remaining_fraction":0.8,"reset_in_seconds":3600}}}
            """
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T20:30:00Z"))
        let active = try read(.antigravity, contents: fixture, now: now)
        XCTAssertEqual(active.windows.first?.percentText, "90")
        XCTAssertNotNil(active.windows.first { $0.name == "Estimated cost" }?.valueText)
        XCTAssertEqual(active.windows.last?.percent ?? 0, 0.2, accuracy: 0.001)
        let expired = try read(.antigravity, contents: fixture, now: now.addingTimeInterval(1_800))
        XCTAssertEqual(expired.windows.last?.hasKnownPercent, false)
        XCTAssertTrue(active.tokenHistory.isEmpty)
    }

    func testFactoryReadsOwnUsageAndSeparatesQuotaPools() throws {
        let record = """
            {"sessionId":"one","tokenUsage":{"inputTokens":70,"outputTokens":20,"factoryCredits":7},
             "inclusiveTokenUsage":{"inputTokens":700,"outputTokens":200}}
            """
        let usage = try read(.droid, contents: record)
        XCTAssertEqual(usage.windows.first?.percentText, "90")
        XCTAssertEqual(usage.windows.first { $0.name == "Recorded spend" }?.percentText, "7 Factory credits")
        XCTAssertNil(usage.windows.first { $0.name == "Estimated cost" }?.valueText)
        let quotas = AdditionalProvider.factoryWindows(from: Data("""
            {"limits":{"standard":{"weekly":{"usedPercent":23,"windowEnd":null}},
                       "core":{"weekly":{"usedPercent":0,"windowEnd":null}}}}
            """.utf8))
        XCTAssertEqual(quotas.map(\.name), ["Standard · Weekly", "Droid Core · Weekly"])
        XCTAssertEqual(quotas.map(\.percentText), ["23%", "0%"])
        let headless = try read(.droid, contents: """
            {"type":"result","session_id":"one","usage":{"input_tokens":7,"output_tokens":2,
              "cache_read_input_tokens":60,"cache_creation_input_tokens":21,"factory_credits":7}}
            """)
        XCTAssertEqual(headless.windows.first?.percentText, "90")
        XCTAssertEqual(headless.windows.first { $0.name == "Recorded spend" }?.percentText, "7 Factory credits")
    }

    func testClineDeduplicatesTaskIndexAndPreservesExplicitZeroCost() throws {
        let record = #"{"id":"one","tokensIn":8,"tokensOut":2,"cacheReads":4,"totalCost":0}"#
        let usage = try read(.cline, contents: "[\(record),\(record)]")
        XCTAssertEqual(usage.windows.first?.percentText, "14")
        XCTAssertNotNil(usage.windows.first { $0.name == "Estimated cost" }?.valueText)
        XCTAssertEqual(usage.windows.last?.name, "Quota unavailable")
    }

    func testClineKeepsAggregateAndDatedMessageUsageSeparate() throws {
        let file = try fixture("""
            {"session_id":"one","metadata":{"usage":{"inputTokens":90,"outputTokens":10,"totalCost":2}}}
            """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let message = #"{"id":"same","role":"assistant","ts":1795298400000,"metrics":{"inputTokens":8,"outputTokens":2}}"#
        let transcript = file.deletingPathExtension().appendingPathExtension("messages.json")
        try Data("{\"messages\":[\(message),\(message)]}".utf8).write(to: transcript)
        let usage = try XCTUnwrap(AdditionalProvider.cline.read(path: file.path, commandHint: ""))
        XCTAssertEqual(usage.windows.first?.percentText, "100")
        XCTAssertEqual(usage.tokenHistory.map(\.tokens), [10])
    }

    func testAuggieUsesDedicatedTokenNodesAndPrefersSessionCreditCounter() throws {
        let usage = try read(.auggie, contents: """
            {"sessionId":"one","creditUsage":7,"chatHistory":[{"exchange":{"request_id":"req","response_nodes":[
              {"id":1,"type":8,"token_usage":{"input_tokens":100}},
              {"id":2,"type":10,"timestamp_ms":1795298400000,"token_usage":{"input_tokens":13,"output_tokens":2}},
              {"id":2,"type":10,"timestamp_ms":1795298400000,"token_usage":{"input_tokens":13,"output_tokens":2}},
              {"id":3,"type":9,"billing_metadata":{"credits_consumed":10,"transaction_id":"bill"}}
            ]}}]}
            """)
        XCTAssertEqual(usage.tokenHistory.map(\.tokens), [15])
        XCTAssertEqual(usage.windows.first { $0.name == "Recorded spend" }?.percentText, "7 Augment credits")
        let quota = AdditionalProvider.creditWindows(from: "Credits Used: 23 / 100 credits", provider: .auggie)
        XCTAssertEqual(quota.first?.percent, 0.23)
    }

    func testAmpLedgerAndMessageUsageDoNotOverlap() throws {
        let usage = try read(.amp, contents: """
            {"id":"one","usageLedger":{"events":[{"id":"r","timestamp":"2026-11-21T20:00:00Z","tokens":{"total":16},"credits":2}]},
             "messages":[{"role":"assistant","usage":{"totalTokens":16}}]}
            """)
        XCTAssertEqual(usage.windows.first?.percentText, "16")
        XCTAssertEqual(usage.tokenHistory.map(\.tokens), [16])
        XCTAssertEqual(usage.windows.first { $0.name == "Recorded spend" }?.percentText, "2 Amp credits")
        let quota = AdditionalProvider.creditWindows(
            from: "**Amp Megawatt Subscription:** 68% other usage and 97% orb usage remaining - resets upon renewal in 5 days",
            provider: .amp
        )
        XCTAssertEqual(quota.map(\.percentText), ["32%", "3%"])
        let balance = AdditionalProvider.creditWindows(from: "Individual: $24.20 remaining", provider: .amp)
        XCTAssertEqual(balance.first?.hasKnownPercent, false)
        XCTAssertNotNil(balance.first?.valueText)
    }

    func testOpenHandsReportsConfiguredBudgetAndDoesNotRecountCache() throws {
        let usage = try read(.openhands, contents: """
            {"id":"session","max_budget_per_run":10,"stats":{"usage_to_metrics":{
              "default":{"accumulated_cost":2,"accumulated_token_usage":{
                "prompt_tokens":60,"completion_tokens":15,"cache_read_tokens":10}}
            }}}
            """)
        XCTAssertEqual(usage.windows.first?.percentText, "75")
        XCTAssertEqual(usage.windows.last?.name, "Conversation budget")
        XCTAssertEqual(usage.windows.last?.percent, 0.2)
    }

    @MainActor
    func testConfiguredProviderIsReadViaNormalRefresh() async throws {
        let root = try fixture(#"[{"id":"demo","tokensIn":5,"tokensOut":1,"totalCost":0}]"#)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var settings = ProviderSettings.builtIn(id: "cline", displayName: "Cline", commandHint: "",
                                                symbolName: "terminal", dataSource: .localAdapter)
        settings.usagePath = root.path
        settings.isEnabled = true
        XCTAssertTrue(settings.availableDataSources.contains(.localAdapter))
        let refresh = UsageRefreshStore()
        refresh.pullNow(providers: [settings])
        for _ in 0..<100 where refresh.isRefreshing {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(refresh.refreshError)
        XCTAssertEqual(refresh.liveUsageByProvider["cline"]?.windows.first?.percentText, "6")
    }

    private func read(_ provider: AdditionalProvider, contents: String, now: Date = Date()) throws -> ProviderLiveUsage {
        let file = try fixture(contents)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        return try XCTUnwrap(provider.read(path: file.path, commandHint: "", now: now))
    }

    private func fixture(_ contents: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("usage.json")
        try Data(contents.utf8).write(to: file)
        return file
    }
}
