import AppIntents
import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OloWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextUpWidget()
        OloLiveActivity()
        if #available(iOS 18.0, *) {
            AskOloControl()
        }
    }
}

// MARK: Ask Olo control (iOS 18): one button that opens Quick Ask with the microphone listening.
// Add it in Control Center, put it on the Lock Screen, or choose it for the Action Button.

@available(iOS 18.0, *)
struct AskOloControl: ControlWidget {
    static let kind = "com.helius.olo.AskOloControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: AskOloControl.kind) {
            ControlWidgetButton(action: OpenQuickAskIntent()) {
                Label("Ask Olo", systemImage: "waveform")
            }
        }
        .displayName("Ask Olo")
        .description("Opens Quick Ask, listening for your question.")
    }
}

// MARK: Home Screen widget: what is next, with Olo

struct NextUpEntry: TimelineEntry {
    let date: Date
    let snapshot: OloSnapshot?
}

struct NextUpProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextUpEntry {
        NextUpEntry(date: Date(), snapshot: OloSnapshot(line: "Your day, at a glance.", nextTitle: "Next in your day", nextStart: Date().addingTimeInterval(1800), updated: Date()))
    }
    func getSnapshot(in context: Context, completion: @escaping (NextUpEntry) -> Void) {
        completion(NextUpEntry(date: Date(), snapshot: SharedStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextUpEntry>) -> Void) {
        let snap = SharedStore.read()
        // Look again when the next event starts, or in an hour.
        let again = snap?.nextStart.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [NextUpEntry(date: Date(), snapshot: snap)], policy: .after(again)))
    }
}

struct NextUpView: View {
    let entry: NextUpEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OloFace(mood: .idle, size: 44, animated: false)
            Spacer(minLength: 0)
            if let s = entry.snapshot, let title = s.nextTitle, let start = s.nextStart, start > entry.date {
                Text(title).font(.headline).lineLimit(2)
                Text(start, style: .time).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(entry.snapshot?.line ?? "Open Olo to see your day.").font(.subheadline).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OloNextUp", provider: NextUpProvider()) { entry in
            NextUpView(entry: entry)
        }
        .configurationDisplayName("Next up")
        .description("The next thing in your day, with Olo.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: Live Activity: Olo on the Lock Screen and in the Dynamic Island

struct OloLockView: View {
    let state: OloActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            OloFace(mood: state.mood, size: 52, animated: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.line).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let title = state.nextTitle, let start = state.nextStart {
                    HStack(spacing: 4) {
                        Text(title).lineLimit(1)
                        Text(start, style: .relative).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

struct OloLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OloActivityAttributes.self) { context in
            OloLockView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OloFace(mood: context.state.mood, size: 46, animated: false)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.line).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let title = context.state.nextTitle, let start = context.state.nextStart {
                        HStack {
                            Text(title).lineLimit(1)
                            Spacer()
                            Text(start, style: .relative).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            } compactLeading: {
                OloFace(mood: context.state.mood, size: 22, animated: false)
            } compactTrailing: {
                if let start = context.state.nextStart, start > Date() {
                    Text(start, style: .timer).monospacedDigit().frame(maxWidth: 50)
                } else {
                    Text("Olo").font(.caption2.weight(.semibold))
                }
            } minimal: {
                OloFace(mood: context.state.mood, size: 20, animated: false)
            }
        }
    }
}
