import Foundation
import SQLite3

struct RecordedTokenUsage: Sendable {
    let occurredAt: Date
    let tokens: Int
}

struct TokenPeriodSummary: Equatable, Sendable {
    let tokens: Int64
    let count: Int

    static func summarize(_ events: [RecordedTokenUsage], in range: Range<Date>) -> Self? {
        var count = 0
        var total: Int64 = 0
        for event in events where range.contains(event.occurredAt) && event.tokens >= 0 {
            let (sum, overflow) = total.addingReportingOverflow(Int64(event.tokens))
            guard !overflow else { return nil }
            total = sum
            count += 1
        }
        return count == 0 ? nil : Self(tokens: total, count: count)
    }
}

enum UsagePeriods {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func range(_ mode: DisplayMode, at now: Date) -> Range<Date>? {
        switch mode {
        case .providerCycles: nil
        case .fiveHours: now.addingTimeInterval(-5 * 3600)..<now
        case .oneWeek: calendarRange(.weekOfYear, at: now)
        case .oneMonth: calendarRange(.month, at: now)
        }
    }

    static func range(_ period: ReportPeriod, at now: Date, from start: Date, through end: Date) -> Range<Date>? {
        switch period {
        case .snapshot: return nil
        case .currentWeek: return calendarRange(.weekOfYear, at: now)
        case .currentMonth: return calendarRange(.month, at: now)
        case .currentYear: return calendarRange(.year, at: now)
        case .custom:
            let first = utc.startOfDay(for: start)
            guard let afterLast = utc.date(byAdding: .day, value: 1, to: utc.startOfDay(for: end)),
                  first < afterLast else { return nil }
            return first..<afterLast
        }
    }

    private static func calendarRange(_ component: Calendar.Component, at now: Date) -> Range<Date>? {
        utc.dateInterval(of: component, for: now).map { $0.start..<$0.end }
    }
}

/// Use the imported database as an alternative source to local session logs.
struct ImportedUsageQuery: Equatable, Sendable {
    let url: URL
    let range: Range<Date>
    var revision = 0

    func read() throws -> [String: TokenPeriodSummary] {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        func databaseError() -> NSError {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            return NSError(domain: "VibeMeasure.SQLite", code: Int(sqlite3_errcode(database)),
                           userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard openResult == SQLITE_OK else { throw databaseError() }
        // The shared view omits superseded records. Pre-migration databases have only the table.
        var schema: OpaquePointer?
        defer { sqlite3_finalize(schema) }
        let check = "SELECT 1 FROM sqlite_master WHERE type='view' AND name='reportable_usage_events'"
        guard sqlite3_prepare_v2(database, check, -1, &schema, nil) == SQLITE_OK else { throw databaseError() }
        let match = sqlite3_step(schema)
        guard match == SQLITE_ROW || match == SQLITE_DONE else { throw databaseError() }
        let source = match == SQLITE_ROW ? "reportable_usage_events" : "usage_events"

        // Bind the UTC date and time up to seconds. Midnight itself and all its fractions
        // sort after that prefix, giving exact inclusive-start and exclusive-end boundaries.
        let query = """
            SELECT tool_id, SUM(total_tokens), COUNT(*) FROM \(source)
            WHERE occurred_at >= ?1 AND occurred_at < ?2
            GROUP BY tool_id
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        let formatter = ISO8601DateFormatter()
        for (index, date) in [range.lowerBound, range.upperBound].enumerated() {
            let key = String(formatter.string(from: date).prefix(19))
            let result = key.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
        var summaries: [String: TokenPeriodSummary] = [:]
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let key = sqlite3_column_text(statement, 0) {
                summaries[String(cString: key)] = TokenPeriodSummary(tokens: sqlite3_column_int64(statement, 1),
                                                                     count: Int(sqlite3_column_int64(statement, 2)))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return summaries
    }
}
