import Foundation

struct SessionTokenRecord: Sendable {
    let id: String
    let timestamp: Date
    let total: Int
    var model: String?
}

func distinctTokenRecords(_ records: [SessionTokenRecord]) -> [SessionTokenRecord] {
    var unique: [String: SessionTokenRecord] = [:]
    for record in records {
        if let previous = unique[record.id],
           (previous.timestamp, previous.total) > (record.timestamp, record.total) { continue }
        unique[record.id] = record
    }
    return unique.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
}

extension Array where Element == SessionTokenRecord {
    var recordedHistory: [RecordedTokenUsage] {
        map { RecordedTokenUsage(occurredAt: $0.timestamp, tokens: $0.total) }
    }
}

// Cache extracted counters, never transcripts. Size and modification date also detect appended and replaced files.
final class SessionFileCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [URL: (size: Int, modified: Date, value: Value)] = [:]

    func contents(of file: URL, parse: (Data) throws -> Value) throws -> Value {
        let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = attributes.fileSize, let modified = attributes.contentModificationDate else {
            return try parse(Data(contentsOf: file, options: .mappedIfSafe))
        }
        if let cached = lock.withLock({ entries[file] }), cached.size == size, cached.modified == modified {
            return cached.value
        }
        let value = try parse(Data(contentsOf: file, options: .mappedIfSafe))
        lock.withLock { entries[file] = (size, modified, value) }
        return value
    }
}

func forEachJSONLine(in data: Data, containing key: Data? = nil, _ body: (Data) -> Void) {
    let newline = Data([10])
    var start = data.startIndex
    while start < data.endIndex {
        let end = data.range(of: newline, in: start..<data.endIndex)?.lowerBound ?? data.endIndex
        if end > start {
            let line = data[start..<end]
            if key.map({ line.range(of: $0) != nil }) ?? true {
                body(line)
            }
        }
        start = end == data.endIndex ? end : end + 1
    }
}
