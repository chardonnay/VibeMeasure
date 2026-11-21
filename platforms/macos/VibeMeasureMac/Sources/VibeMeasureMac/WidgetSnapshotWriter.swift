import Foundation
import OSLog
import WidgetKit

enum WidgetSnapshotWriter {
    struct Provider: Encodable {
        let display_name: String
        let rows: [String]
    }
    struct Snapshot: Encodable {
        let generated_at: Date
        let providers: [Provider]
    }

    static func snapshot(providers: [ProviderSettings], readings: [String: ProviderLiveUsage]) -> Snapshot {
        let enabled = providers.filter(\.isEnabled).map { provider in
            let preview = ProviderPreview(settings: provider, liveUsage: readings[provider.id])
            let rows = preview.windows.map { window in
                if !window.hasKnownPercent && window.valueText == nil && preview.status == "Local" {
                    return "\(window.name) · \(window.resetText)"
                }
                return "\(window.name) · \(window.percentText)"
            }
            return Provider(display_name: provider.displayName, rows: rows)
        }
        return Snapshot(generated_at: Date(), providers: enabled)
    }

    static func publish(providers: [ProviderSettings], readings: [String: ProviderLiveUsage]) {
        // Only a packaged app and its extension have a shared app-group container.
        guard let group = Bundle.main.object(forInfoDictionaryKey: "VibeMeasureAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot(providers: providers, readings: readings))
            try data.write(to: container.appendingPathComponent("widget.json"), options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: "VibeMeasureWidget")
        } catch {
            Logger(subsystem: "org.vibemeasure", category: "widget").error("Could not publish widget snapshot: \(error.localizedDescription)")
        }
    }
}
