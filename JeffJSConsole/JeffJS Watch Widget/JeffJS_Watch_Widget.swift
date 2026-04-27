import WidgetKit
import SwiftUI
import JeffJS

// MARK: - Timeline Provider

struct JeffJSProvider: TimelineProvider {
    func placeholder(in context: Context) -> JeffJSEntry {
        JeffJSEntry(date: .now, result: "JeffJS", command: "ready")
    }

    func getSnapshot(in context: Context, completion: @escaping (JeffJSEntry) -> Void) {
        let entry = JeffJSEntry(
            date: .now,
            result: SharedConsoleData.lastResult.isEmpty ? "> _" : SharedConsoleData.lastResult,
            command: SharedConsoleData.lastCommand.isEmpty ? "JeffJS" : SharedConsoleData.lastCommand
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JeffJSEntry>) -> Void) {
        // Run the widget script in a fresh JeffJS environment
        Task { @MainActor in
            let script = SharedConsoleData.widgetScript
            let env = JeffJSEnvironment()
            var output = ""
            env.onConsoleMessage = { _, msg in
                output = msg
            }

            let result = await env.evalAsync(script, timeout: 8)
            switch result {
            case .success(let str):
                if let str, str != "undefined" {
                    output = str
                }
            case .exception(let msg):
                output = msg
            }
            env.teardown()

            let displayResult = output.isEmpty ? SharedConsoleData.lastResult : output
            if !output.isEmpty {
                SharedConsoleData.lastResult = output
                SharedConsoleData.lastUpdate = .now
            }

            let entry = JeffJSEntry(
                date: .now,
                result: displayResult.isEmpty ? "> _" : displayResult,
                command: script.prefix(30).trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // Refresh every 15 minutes
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
            let timeline = Timeline(entries: [entry], policy: .after(next))
            completion(timeline)
        }
    }
}

// MARK: - Entry

struct JeffJSEntry: TimelineEntry {
    let date: Date
    let result: String
    let command: String
}

// MARK: - Widget Views

struct JeffJSWidgetEntryView: View {
    var entry: JeffJSEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        case .accessoryInline:
            inlineView
        case .accessoryCorner:
            cornerView
        default:
            rectangularView
        }
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Text("JS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text(truncated(8))
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("JeffJS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text("> " + truncated(60))
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(2)
                .foregroundColor(.white)
        }
    }

    private var inlineView: some View {
        Text("JS: " + truncated(20))
            .font(.system(size: 9, design: .monospaced))
    }

    private var cornerView: some View {
        Text(truncated(10))
            .font(.system(size: 9, design: .monospaced))
            .widgetLabel {
                Text("JeffJS")
            }
    }

    private func truncated(_ max: Int) -> String {
        let text = entry.result
        if text.count <= max { return text }
        return String(text.prefix(max - 1)) + "\u{2026}"
    }
}

// MARK: - Widget

@main
struct JeffJSWidget: Widget {
    let kind = "JeffJSWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JeffJSProvider()) { entry in
            JeffJSWidgetEntryView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("JeffJS Console")
        .description("Shows JS evaluation results on your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}
