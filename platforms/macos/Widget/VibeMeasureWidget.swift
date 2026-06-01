import WidgetKit
import SwiftUI

struct VibeMeasureEntry: TimelineEntry {
    let date: Date
    let providers: [WidgetProviderPreview]
}

struct VibeMeasureTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> VibeMeasureEntry {
        VibeMeasureEntry(date: Date(), providers: WidgetProviderPreview.samples)
    }

    func getSnapshot(in context: Context, completion: @escaping (VibeMeasureEntry) -> Void) {
        completion(VibeMeasureEntry(date: Date(), providers: WidgetProviderPreview.samples))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VibeMeasureEntry>) -> Void) {
        let entry = VibeMeasureEntry(date: Date(), providers: WidgetProviderPreview.samples)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300))))
    }
}

struct VibeMeasureWidgetView: View {
    let entry: VibeMeasureEntry

    var body: some View {
        HStack(spacing: 14) {
            ForEach(entry.providers) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.name)
                        .font(.caption.weight(.bold))
                    HStack {
                        Text(provider.window)
                        Spacer()
                        Text(provider.percent)
                            .foregroundStyle(.green)
                            .fontWeight(.bold)
                    }
                    ProgressView(value: provider.value)
                        .tint(.green)
                    Text(provider.note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

@main
struct VibeMeasureWidget: Widget {
    let kind = "VibeMeasureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VibeMeasureTimelineProvider()) { entry in
            VibeMeasureWidgetView(entry: entry)
        }
        .configurationDisplayName("VibeMeasure")
        .description("Shows selected provider usage windows from verified or manual data.")
        .supportedFamilies([.systemMedium])
    }
}

struct WidgetProviderPreview: Identifiable {
    let id: String
    let name: String
    let window: String
    let percent: String
    let value: Double
    let note: String

    static let samples = [
        WidgetProviderPreview(
            id: "claude",
            name: "Claude",
            window: "5-Hour",
            percent: "4%",
            value: 0.04,
            note: "Manual setup"
        ),
        WidgetProviderPreview(
            id: "codex",
            name: "Codex",
            window: "5-Hour",
            percent: "1%",
            value: 0.01,
            note: "Local data"
        )
    ]
}

