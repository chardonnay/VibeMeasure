import CoreFoundation
import Foundation
import SwiftUI

enum AdditionalProvider: String {
    case antigravity, cline, auggie, amp, openhands
    case droid = "factory-droid"

    var sourceHint: String {
        switch self {
        case .antigravity: "~/.gemini/antigravity-cli/vibemeasure-usage.json"
        case .droid: "~/.factory/sessions"
        case .cline: "~/.cline/data/sessions or a Cline task history file"
        case .auggie: "~/.augment/sessions and auggie account status"
        case .amp: "~/.local/share/amp/threads and amp usage"
        case .openhands: "~/.openhands/conversations or your SDK persistence directory"
        }
    }

    private var defaultPaths: [String] {
        let env = ProcessInfo.processInfo.environment
        switch self {
        case .antigravity: return [sourceHint]
        case .droid: return [sourceHint]
        case .cline:
            return ["~/.cline/data/sessions", "~/.cline/data/state/taskHistory.json",
                    "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/state/taskHistory.json",
                    "~/Library/Application Support/Code - Insiders/User/globalStorage/saoudrizwan.claude-dev/state/taskHistory.json"]
        case .auggie: return [(env["AUGMENT_HOME"] ?? "~/.augment") + "/sessions"]
        case .amp:
            let paths = env["AMP_DATA_DIR"]?.split(separator: ",").map(String.init)
                ?? [(env["XDG_DATA_HOME"] ?? "~/.local/share") + "/amp"]
            return paths.map { $0 + "/threads" }
        case .openhands: return ["~/.openhands/conversations"]
        }
    }

    func read(path: String, commandHint: String, now: Date = Date()) throws -> ProviderLiveUsage? {
        let paths = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPaths : [path]
        var result = ProviderReadings()
        var seen: Set<String> = []
        for file in try files(at: paths) {
            do {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                let fallbackID = file.lastPathComponent.replacingOccurrences(of: ".settings.json", with: "")
                if self == .antigravity, file.pathExtension == "jsonl" {
                    for line in data.split(separator: 10) {
                        guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? Record,
                              let step = event["step_update"] as? Record,
                              step["state"] as? String == "DONE", let usage = step["usage"] as? Record,
                              let total = count(usage["total_tokens"]),
                              let session = step["conversation_id"] as? String,
                              let index = count(step["step_index"]),
                              seen.insert("step:\(session):\(index)").inserted else { continue }
                        result.addTokens(total, date: timestamp(event["timestamp"]))
                    }
                    continue
                }
                let payload = try JSONSerialization.jsonObject(with: data)
                if self == .cline, let tasks = payload as? [Record] {
                    for task in tasks { readClineTask(task, seen: &seen, result: &result) }
                } else if let data = payload as? Record {
                    readRecord(data, file: file, fallbackID: fallbackID, now: now, seen: &seen, result: &result)
                }
            } catch {
                // A provider may rewrite a file during refresh. Existing complete readings still count.
                continue
            }
        }

        if self == .amp || self == .auggie {
            let command = self == .amp ? ["usage"] : ["account", "status"]
            if let executable = Self.executable(commandHint),
               let response = try? LocalAgentCommand.run(executable: executable, arguments: command),
               response.status == 0 {
                let output = String(decoding: response.stdout, as: UTF8.self)
                result.quotas.append(contentsOf: Self.creditWindows(from: output, provider: self))
            }
        }
        return result.preview
    }

    private func files(at paths: [String]) throws -> [URL] {
        let manager = FileManager.default
        var files: Set<URL> = []
        for path in paths {
            let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                // An explicitly selected file can be a provider export with a different name.
                let info = try root.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if info.isRegularFile == true, (info.fileSize ?? Int.max) <= 64 * 1_024 * 1_024 {
                    files.insert(root.resolvingSymlinksInPath())
                }
                continue
            }
            guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let entry as URL in entries {
                guard matches(entry.lastPathComponent),
                      let info = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      info.isRegularFile == true, (info.fileSize ?? Int.max) <= 64 * 1_024 * 1_024 else { continue }
                files.insert(entry.resolvingSymlinksInPath())
            }
        }
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        return dated.sorted { first, second in
            if first.1 == second.1 { return first.0.path < second.0.path }
            return first.1 > second.1
        }.map(\.0)
    }

    private func matches(_ filename: String) -> Bool {
        switch self {
        case .antigravity: filename == "vibemeasure-usage.json" || filename.hasSuffix(".jsonl")
        case .droid: filename.hasSuffix(".settings.json") || filename == "factory-limits.json"
        case .cline: filename.hasSuffix(".json") && !filename.hasSuffix(".messages.json")
        case .auggie, .amp: filename.hasSuffix(".json") && filename != "session.json"
        case .openhands: filename == "base_state.json"
        }
    }

    private func readRecord(_ data: Record, file: URL, fallbackID: String, now: Date,
                            seen: inout Set<String>, result: inout ProviderReadings) {
        switch self {
        case .antigravity:
            guard data["product"] as? String == "antigravity",
                  seen.insert("latest-status-snapshot").inserted else { return }
            result.plan = data["plan_tier"] as? String
            if let context = data["context_window"] as? Record {
                result.snapshotTokens = sumCounts(context, ["total_input_tokens", "total_output_tokens"])
            }
            result.addUSD(amount((data["cost"] as? Record)?["total_usd"]))
            // Quota buckets from the provider may be time-bound or expressed as a balance.
            let buckets = data["quota"] as? [String: Record] ?? [:]
            for (key, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
                guard bucket["disabled"] as? Bool != true else { continue }
                let reset = timestamp(bucket["reset_time"])
                let captured = timestamp(data["captured_at"])
                let expiry = reset ?? captured.flatMap { date in
                    amount(bucket["reset_in_seconds"]).flatMap { $0 <= 366 * 86_400 ? date.addingTimeInterval($0) : nil }
                }
                let expired = expiry.map { $0 <= now } ?? false
                let note = expiry.map { WindowPreview.resetText(resetsAt: $0, relativeTo: now) }
                    ?? "Reported by Antigravity"
                let remaining = amount(bucket["remaining_fraction"]).flatMap { $0 <= 1 ? $0 : nil }
                let balance = expired ? nil : amount(bucket["remaining_amount"])?.formatted()
                if remaining != nil || amount(bucket["remaining_amount"]) != nil {
                    result.quotas.append(WindowPreview(name: "\(key) quota", percent: expired ? nil : remaining.map { 1 - $0 },
                                                       resetText: note, valueText: remaining == nil ? balance.map { "\($0) remaining" } : nil, resetsAt: expiry))
                }
            }
        case .droid:
            if data["limits"] is Record {
                result.quotas.append(contentsOf: Self.factoryWindows(data, now: now))
            } else if let usage = data["tokenUsage"] as? Record {
                let id = data["sessionId"] as? String ?? fallbackID
                guard seen.insert(id).inserted else { return }
                // Use the session's own usage; inclusiveTokenUsage can also count the child sessions.
                result.addTokens(sumCounts(usage, ["inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens"]))
                result.addCredits(amount(usage["factoryCredits"]), unit: "Factory credits")
            } else if data["type"] as? String == "result", let usage = data["usage"] as? Record {
                let id = data["session_id"] as? String ?? fallbackID
                guard seen.insert(id).inserted else { return }
                result.addTokens(sumCounts(usage, ["input_tokens", "output_tokens",
                                                   "cache_read_input_tokens", "cache_creation_input_tokens"]))
                result.addCredits(amount(usage["factory_credits"]), unit: "Factory credits")
            }
        case .cline:
            let meta = data["metadata"] as? Record ?? [:]
            guard let id = data["session_id"] as? String, seen.insert(id).inserted else { return }
            let usage = (meta["usage"] ?? meta["aggregateUsage"]) as? Record ?? [:]
            let fields = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]
            let history = Self.clineHistory(beside: file, fields: fields)
            result.addTokens(sumCounts(usage, fields) ?? sum(history.map(\.tokens)))
            result.history.append(contentsOf: history)
            result.addUSD(amount(usage["totalCost"] ?? meta["totalCost"]))
        case .auggie:
            guard let turns = data["chatHistory"] as? [Record] else { return }
            let id = data["sessionId"] as? String ?? fallbackID
            guard seen.insert(id).inserted else { return }
            let sessionCredits = amount(data["creditUsage"])
            var transactions: Set<String> = []
            result.addCredits(sessionCredits, unit: "Augment credits")
            for (turnIndex, turn) in turns.enumerated() {
                guard let exchange = turn["exchange"] as? Record,
                      let nodes = exchange["response_nodes"] as? [Record] else { continue }
                let request = exchange["request_id"] as? String ?? String(turnIndex)
                let hasDedicatedUsage = nodes.contains { count($0["type"]) == 10 && $0["token_usage"] is Record }
                for (index, node) in nodes.enumerated() {
                    if let usage = node["token_usage"] as? Record,
                       count(node["type"]) == (hasDedicatedUsage ? 10 : 8),
                       seen.insert("\(id):\(request):\(count(node["id"]) ?? index)").inserted {
                        result.addTokens(sumCounts(usage, ["input_tokens", "output_tokens",
                                                           "cache_read_input_tokens", "cache_creation_input_tokens"]),
                                         date: timestamp(node["timestamp_ms"]))
                    }
                    if sessionCredits == nil, let billing = node["billing_metadata"] as? Record,
                       let transaction = billing["transaction_id"] as? String,
                       transactions.insert(transaction).inserted {
                        result.addCredits(amount(billing["credits_consumed"]), unit: "Augment credits")
                    }
                }
            }
        case .amp:
            guard let id = data["id"] as? String, seen.insert(id).inserted else { return }
            let ledger = (data["usageLedger"] as? Record)?["events"] as? [Record] ?? []
            let messages = data["messages"] as? [Record] ?? []
            var recordedLedgerTokens = false
            for (index, event) in ledger.enumerated() {
                let identity = event["id"] as? String ?? String(index)
                guard seen.insert("\(id):\(identity)").inserted else { continue }
                if let tokens = event["tokens"] as? Record, let total = count(tokens["total"]) {
                    result.addTokens(total, date: timestamp(event["timestamp"]))
                    recordedLedgerTokens = true
                }
                result.addCredits(amount(event["credits"]), unit: "Amp credits")
            }
            if !recordedLedgerTokens {
                for message in messages where message["role"] as? String == "assistant" {
                    guard let usage = message["usage"] as? Record else { continue }
                    let total = count(usage["totalTokens"]) ?? (
                        count(usage["totalInputTokens"]).flatMap { input in sum([input, count(usage["outputTokens"]) ?? 0]) }
                        ?? sumCounts(usage, ["inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"])
                    )
                    result.addTokens(total, date: timestamp(usage["timestamp"] ?? message["timestamp"]))
                }
            }
        case .openhands:
            guard let stats = data["stats"] as? Record,
                  let metrics = stats["usage_to_metrics"] as? [String: Record],
                  let id = data["id"] as? String, seen.insert(id).inserted else { return }
            let rows = metrics.keys.sorted().compactMap { metrics[$0] }
            let costs = rows.compactMap { amount($0["accumulated_cost"]) }
            let cost = !rows.isEmpty && costs.count == rows.count ? costs.reduce(0, +) : nil
            result.addUSD(cost)
            for metric in rows {
                if let usage = metric["accumulated_token_usage"] as? Record {
                    result.addTokens(sumCounts(usage, ["prompt_tokens", "completion_tokens"]))
                }
            }
            if result.quotas.isEmpty, let budget = amount(data["max_budget_per_run"]), budget > 0, let cost {
                result.quotas.append(WindowPreview(name: "Conversation budget", percent: min(cost / budget, 1),
                                                   resetText: "OpenHands budget for this conversation",
                                                   valueText: "\(cost.formatted(.currency(code: "USD"))) / \(budget.formatted(.currency(code: "USD")))"))
            }
        }
    }

    private func readClineTask(_ task: Record, seen: inout Set<String>, result: inout ProviderReadings) {
        guard let id = task["id"] as? String, seen.insert(id).inserted else { return }
        result.addTokens(sumCounts(task, ["tokensIn", "tokensOut", "cacheReads", "cacheWrites"]))
        result.addUSD(amount(task["totalCost"]))
    }

    private static func clineHistory(beside file: URL, fields: [String]) -> [RecordedTokenUsage] {
        let transcript = file.deletingPathExtension().appendingPathExtension("messages.json")
        guard let size = try? transcript.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1_024 * 1_024,
              let data = try? Data(contentsOf: transcript, options: .mappedIfSafe),
              let json = try? JSONSerialization.jsonObject(with: data) as? Record,
              let messages = json["messages"] as? [Record] else { return [] }
        var seen: Set<String> = []
        return messages.compactMap { message in
            guard message["role"] as? String == "assistant",
                  let metrics = message["metrics"] as? Record, let total = sumCounts(metrics, fields),
                  let date = timestamp(message["ts"]) else { return nil }
            if let id = message["id"] as? String, !seen.insert(id).inserted { return nil }
            return RecordedTokenUsage(occurredAt: date, tokens: total)
        }
    }

    private static func executable(_ name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        let manager = FileManager.default
        let path = (name as NSString).expandingTildeInPath
        let home = manager.homeDirectoryForCurrentUser
        let directories = (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
            + [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        let candidates = path.hasPrefix("/") ? [path] : directories.map { URL(fileURLWithPath: $0).appendingPathComponent(path).path }
        return candidates.first(where: manager.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    static func factoryWindows(from data: Data, now: Date = Date()) -> [WindowPreview] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? Record else { return [] }
        return factoryWindows(json, now: now)
    }

    static func factoryAccountQuotas() async -> [WindowPreview] {
        guard let token = ProcessInfo.processInfo.environment["VIBEMEASURE_FACTORY_ACCESS_TOKEN"],
              !token.isEmpty, token.count <= 8192,
              token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              let endpoint = URL(string: "https://api.factory.ai/api/billing/limits") else { return [] }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoFactoryRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url == endpoint else { return [] }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 262_144 else { return [] }
                data.append(byte)
            }
            return factoryWindows(from: data)
        } catch {
            return []
        }
    }

    private static func factoryWindows(_ data: Record, now: Date) -> [WindowPreview] {
        let groups = data["limits"] as? [String: Record] ?? [:]
        var windows: [WindowPreview] = []
        for (key, label) in [("standard", "Standard"), ("core", "Droid Core")] {
            guard let group = groups[key] else { continue }
            for (cycle, name) in [("fiveHour", "5-hour"), ("weekly", "Weekly"), ("monthly", "Monthly")] {
                guard let item = group[cycle] as? Record,
                      let percent = amount(item["usedPercent"]), percent <= 100 else { continue }
                let reset = timestamp(item["windowEnd"])
                let expired = reset.map { $0 <= now } ?? false
                windows.append(WindowPreview(name: "\(label) · \(name)", percent: expired ? nil : percent / 100,
                                             resetText: reset.map { WindowPreview.resetText(resetsAt: $0, relativeTo: now) }
                                                 ?? "Factory reported no reset date", resetsAt: reset))
            }
        }
        if let cents = amount(data["extraUsageBalanceCents"]), data["extraUsageAllowed"] as? Bool == true {
            windows.append(WindowPreview(name: "Extra usage balance", percent: nil, resetText: "Factory prepaid credit",
                                         valueText: (cents / 100).formatted(.currency(code: "USD"))))
        }
        return windows
    }

    static func creditWindows(from output: String, provider: Self) -> [WindowPreview] {
        let ansi = #/\x1B\[[0-?]*[ -\/]*[@-~]/#
        let clean = output.replacing(ansi, with: "").replacingOccurrences(of: "**", with: "")
        var windows: [WindowPreview] = []
        for raw in clean.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if provider == .amp,
               let match = line.firstMatch(of: #/^([^:]+):\s*\$([0-9,.]+)(?:\s*\/\s*\$([0-9,.]+))?\s+remaining\b/#) {
                guard let remaining = amountText(String(match.2)) else { continue }
                let ceiling = match.3.flatMap { amountText(String($0)) }
                let percent = ceiling.flatMap { $0 > 0 && remaining <= $0 ? 1 - remaining / $0 : nil }
                windows.append(WindowPreview(name: String(match.1), percent: percent,
                                             resetText: "Amp credit balance", valueText: "\(remaining.formatted(.currency(code: "USD"))) remaining"))
            } else if provider == .amp, line.contains("Subscription:") {
                let reset = line.range(of: "resets upon renewal").map { String(line[$0.lowerBound...]) } ?? "Amp subscription"
                for match in line.matches(of: #/([0-9]{1,3})%\s+(other|orb)\s+usage/#) where line.contains("remaining") {
                    guard let percent = Double(match.1), (0...100).contains(percent) else { continue }
                    windows.append(WindowPreview(name: "Amp \(match.2) usage", percent: 1 - percent / 100, resetText: reset))
                }
            } else if provider == .auggie {
                if let match = line.firstMatch(of: #/^(?:Credits Used|Usage):\s*([0-9,.]+)\s*\/\s*([0-9,.]+)\s*(?:credits)?\s*(?:\([^)]*\))?\s*$/#.ignoresCase()),
                   let used = amountText(String(match.1)), let limit = amountText(String(match.2)), limit > 0 {
                    windows.append(WindowPreview(name: "Augment credit usage", percent: min(used / limit, 1),
                                                 resetText: "Reported by auggie account status", valueText: "\(used.formatted()) / \(limit.formatted()) credits"))
                } else if let match = line.firstMatch(of: #/^(Credits Remaining|Remaining Credits|Credit Balance|Monthly (?:Credit )?Allowance):\s*([0-9,.]+)\s*(?:credits)?\s*$/#.ignoresCase()),
                          let value = amountText(String(match.2)) {
                    windows.append(WindowPreview(name: String(match.1), percent: nil, resetText: "Reported by auggie account status",
                                                 valueText: "\(value.formatted()) credits"))
                }
            }
        }
        return windows
    }
}

private final class NoFactoryRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private typealias Record = [String: Any]

private func count(_ value: Any?) -> Int? {
    guard let value = amount(value), value.rounded(.towardZero) == value else { return nil }
    return Int(exactly: value)
}

private func amount(_ value: Any?) -> Double? {
    let number: Double?
    if let boxed = value as? NSNumber, CFGetTypeID(boxed) != CFBooleanGetTypeID() {
        number = boxed.doubleValue
    } else if let string = value as? String {
        number = Double(string)
    } else {
        number = nil
    }
    return number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
}

private func amountText(_ value: String) -> Double? {
    amount(value.replacingOccurrences(of: ",", with: ""))
}

private func sum(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    var total = 0
    for value in values {
        let next = total.addingReportingOverflow(value)
        guard !next.overflow else { return nil }
        total = next.partialValue
    }
    return total
}

private func sumCounts(_ record: Record, _ keys: [String]) -> Int? {
    sum(keys.compactMap { count(record[$0]) })
}

private func timestamp(_ value: Any?) -> Date? {
    if let number = amount(value), number > 0 {
        let seconds = number > 100_000_000_000 ? number / 1_000 : number
        return seconds < 253_402_300_800 ? Date(timeIntervalSince1970: seconds) : nil
    }
    guard let value = value as? String else { return nil }
    return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        ?? (try? Date.ISO8601FormatStyle().parse(value))
}

private struct ProviderReadings {
    var plan: String?
    var tokens: Int?
    var snapshotTokens: Int?
    var usd: Double?
    var credits: (amount: Double, unit: String)?
    var quotas: [WindowPreview] = []
    var history: [RecordedTokenUsage] = []
    var tokenOverflow = false

    mutating func addTokens(_ value: Int?, date: Date? = nil) {
        guard let value else { return }
        if !tokenOverflow {
            tokens = sum([tokens ?? 0, value])
            tokenOverflow = tokens == nil
        }
        if let date { history.append(RecordedTokenUsage(occurredAt: date, tokens: value)) }
    }

    mutating func addUSD(_ value: Double?) {
        if let value { usd = amount((usd ?? 0) + value) }
    }

    mutating func addCredits(_ value: Double?, unit: String) {
        if let value, let total = amount((credits?.amount ?? 0) + value) { credits = (total, unit) }
    }

    var preview: ProviderLiveUsage? {
        guard tokens != nil || snapshotTokens != nil || usd != nil || credits != nil || !quotas.isEmpty else { return nil }
        var windows = [
            WindowPreview(name: tokens == nil && snapshotTokens != nil ? "Conversation tokens" : "Recorded tokens",
                          percent: nil, resetText: "From available provider records",
                          valueText: (tokens ?? snapshotTokens)?.formatted()),
            WindowPreview(name: "Estimated cost", percent: nil, resetText: "USD estimates reported by the source",
                          valueText: usd?.formatted(.currency(code: "USD")))
        ]
        if let credits {
            windows.append(WindowPreview(name: "Recorded spend", percent: nil, resetText: credits.unit,
                                         valueText: "\(credits.amount.formatted()) \(credits.unit)"))
        }
        windows.append(contentsOf: quotas.isEmpty ? [
            WindowPreview(name: "Quota unavailable", percent: nil, resetText: "No current quota reported by the source")
        ] : quotas)
        return ProviderLiveUsage(status: "Local", statusColor: .green, planName: plan, windows: windows, tokenHistory: history)
    }
}
