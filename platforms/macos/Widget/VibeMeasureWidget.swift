import Foundation
import SwiftUI
import WidgetKit

private struct PublishedSnapshot: Decodable {
    let generatedAt: String
    let providers: [PublishedProvider]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case providers
    }
}

private struct PublishedProvider: Decodable {
    let display_name: String
    let rows: [String]
}

private struct VibeMeasureEntry: TimelineEntry {
    let date: Date
    var snapshotDate: Date?
    var providers: [PublishedProvider] = []
    var message: String?
}

private struct VibeMeasureTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> VibeMeasureEntry {
        VibeMeasureEntry(date: Date(), message: "VibeMeasure usage")
    }

    func getSnapshot(in context: Context, completion: @escaping (VibeMeasureEntry) -> Void) {
        completion(readSnapshot())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VibeMeasureEntry>) -> Void) {
        let entry = readSnapshot()
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(300))))
    }

    private func readSnapshot() -> VibeMeasureEntry {
        let now = Date()
        let group = Bundle.main.object(forInfoDictionaryKey: "VibeMeasureAppGroup") as? String
            ?? "group.org.vibemeasure.shared"
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return VibeMeasureEntry(date: now, message: "The shared VibeMeasure container is unavailable.")
        }
        do {
            let data = try Data(contentsOf: container.appendingPathComponent("widget.json"))
            let snapshot = try JSONDecoder().decode(PublishedSnapshot.self, from: data)
            let formatter = ISO8601DateFormatter()
            let wholeSeconds = formatter.date(from: snapshot.generatedAt)
            formatter.formatOptions.insert(.withFractionalSeconds)
            guard let updated = wholeSeconds ?? formatter.date(from: snapshot.generatedAt) else {
                return VibeMeasureEntry(date: now, message: "The snapshot date is invalid.")
            }
            return VibeMeasureEntry(date: now, snapshotDate: updated, providers: snapshot.providers,
                                    message: snapshot.providers.isEmpty ? "Enable a provider in VibeMeasure Settings." : nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return VibeMeasureEntry(date: now, message: "Open VibeMeasure to publish a usage snapshot.")
        } catch {
            return VibeMeasureEntry(date: now, message: "The usage snapshot could not be read.")
        }
    }
}

private struct VibeMeasureWidgetView: View {
    let entry: VibeMeasureEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("VibeMeasure").font(.headline)
                Spacer()
                if let updated = entry.snapshotDate {
                    Text(updated, style: .relative).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Snapshot age: \(updated.formatted())")
                }
            }
            if let message = entry.message {
                Text(message).font(.caption)
            } else {
                ForEach(Array(entry.providers.prefix(3).enumerated()), id: \.offset) { _, provider in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.display_name).font(.caption.bold())
                        Text(provider.rows.isEmpty ? "Usage unavailable" : provider.rows.joined(separator: " · "))
                            .font(.caption2).lineLimit(2)
                    }
                }
                if entry.providers.count > 3 {
                    Text("+\(entry.providers.count - 3) more in VibeMeasure").font(.caption2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct VibeMeasureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VibeMeasureWidget", provider: VibeMeasureTimelineProvider()) {
            VibeMeasureWidgetView(entry: $0)
        }
        .configurationDisplayName("VibeMeasure")
        .description("Shows the latest snapshot of your enabled providers.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
