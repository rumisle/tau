import SwiftUI
import WidgetKit
import ActivityKit

/// The app icon's pink.
private let tauPink = Color(red: 0xF2 / 255.0, green: 0x56 / 255.0, blue: 0x9A / 255.0)
private let doneGreen = Color(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)
private let failedRed = Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)

/// The τ of ChatWaitingNode and the app icon, in its 24 pt box.
struct TauGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24.0
        let origin = CGPoint(x: rect.midX - 11.9 * scale, y: rect.midY - 13.0 * scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            return CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path()
        path.move(to: p(3.2, 10.0))
        path.addQuadCurve(to: p(7.0, 6.6), control: p(3.9, 6.7))
        path.addLine(to: p(20.6, 6.6))
        path.move(to: p(12.6, 6.6))
        path.addLine(to: p(11.9, 15.2))
        path.addQuadCurve(to: p(16.6, 19.4), control: p(11.5, 19.7))
        return path.strokedPath(StrokeStyle(lineWidth: 2.6 * scale, lineCap: .round, lineJoin: .round))
    }
}

/// How long a chat has worked, in whole minutes as of the last update ("4 min"), never seconds
/// (docs/live-activity.md). Once the updates stop (no APNs yet), when it began instead, which stays true.
struct Minutes: View {
    let chat: TauActivityAttributes.Chat
    let isStale: Bool
    var compact = false

    var body: some View {
        if self.isStale {
            Text(self.compact ? "" : "since \(self.chat.since.formatted(date: .omitted, time: .shortened))")
        } else if self.compact {
            Text(self.chat.minutes < 1 ? "now" : self.chat.minutes < 60 ? "\(self.chat.minutes)m" : "\(self.chat.minutes / 60)h")
        } else {
            Text(minutesText(self.chat.minutes))
        }
    }
}

func minutesText(_ minutes: Int) -> String {
    if minutes < 1 {
        return "just now"
    } else if minutes < 60 {
        return "\(minutes) min"
    }
    return "\(minutes / 60) h \(minutes % 60) min"
}

private extension TauActivityAttributes.ContentState {
    var working: [TauActivityAttributes.Chat] {
        return self.chats.filter { $0.state == .working }
    }

    var hasFailed: Bool {
        return self.chats.contains { $0.state == .failed }
    }

    var hasDone: Bool {
        return self.chats.contains { $0.state == .done }
    }
}

/// A chat's state at the end of its row: its minutes while it works, else Done or Failed.
struct ChatStateLabel: View {
    let chat: TauActivityAttributes.Chat
    let isStale: Bool

    var body: some View {
        switch self.chat.state {
        case .working:
            Minutes(chat: self.chat, isStale: self.isStale)
                .foregroundStyle(.secondary)
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(doneGreen)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(failedRed)
        }
    }
}

struct ChatRow: View {
    let chat: TauActivityAttributes.Chat
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2.0) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.chat.title)
                    .font(.system(size: 15.0, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8.0)
                ChatStateLabel(chat: self.chat, isStale: self.isStale)
                    .font(.system(size: 14.0))
                    .monospacedDigit()
            }
            let detail = self.chat.detail ?? (self.chat.state == .working ? "Working" : nil)
            if let detail {
                Text(self.isStale && self.chat.state == .working ? "Open tau for the latest" : detail)
                    .font(.system(size: 13.0))
                    .foregroundStyle(.secondary)
                    .lineLimit(self.chat.state == .working ? 1 : 2)
            }
        }
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<TauActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 12.0) {
            TauGlyph()
                .fill(tauPink)
                .frame(width: 22.0, height: 22.0)
                .padding(.top, 1.0)
            VStack(alignment: .leading, spacing: 10.0) {
                ForEach(self.context.state.chats, id: \.id) { chat in
                    if self.context.state.chats.count > 1, let url = chat.url {
                        Link(destination: url) {
                            ChatRow(chat: chat, isStale: self.context.isStale)
                        }
                    } else {
                        ChatRow(chat: chat, isStale: self.context.isStale)
                    }
                }
                if self.context.state.more > 0 {
                    Text("+\(self.context.state.more) more")
                        .font(.system(size: 13.0))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16.0)
        .activityBackgroundTint(Color(red: 0x0E / 255.0, green: 0x16 / 255.0, blue: 0x21 / 255.0).opacity(0.85))
        .activitySystemActionForegroundColor(.white)
        .foregroundStyle(.white)
        .widgetURL(self.context.state.chats.count == 1 ? self.context.state.chats[0].url : nil)
    }
}

/// The island's right side when compact: one chat's minutes, how many work, or a check or a mark once they are done.
struct CompactTrailing: View {
    let state: TauActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let working = self.state.working
        if working.count == 1 {
            Minutes(chat: working[0], isStale: self.isStale, compact: true)
                .font(.system(size: 14.0, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tauPink)
                .frame(maxWidth: 64.0)
        } else if working.count > 1 {
            Text("\(working.count)")
                .font(.system(size: 15.0, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tauPink)
        } else if self.state.hasFailed {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(failedRed)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(doneGreen)
        }
    }
}

struct TauLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TauActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TauGlyph()
                        .fill(tauPink)
                        .frame(width: 26.0, height: 26.0)
                        .padding(.leading, 4.0)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 8.0) {
                        ForEach(context.state.chats, id: \.id) { chat in
                            if let url = chat.url {
                                Link(destination: url) {
                                    ChatRow(chat: chat, isStale: context.isStale)
                                }
                            }
                        }
                        if context.state.more > 0 {
                            Text("+\(context.state.more) more")
                                .font(.system(size: 13.0))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                TauGlyph()
                    .fill(tauPink)
                    .frame(width: 20.0, height: 20.0)
            } compactTrailing: {
                CompactTrailing(state: context.state, isStale: context.isStale)
            } minimal: {
                if context.state.working.isEmpty {
                    Image(systemName: context.state.hasFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(context.state.hasFailed ? failedRed : doneGreen)
                } else {
                    TauGlyph()
                        .fill(tauPink)
                        .frame(width: 18.0, height: 18.0)
                }
            }
            .widgetURL(context.state.chats.count == 1 ? context.state.chats[0].url : nil)
            .keylineTint(tauPink)
        }
    }
}

@main
struct TauWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TauLiveActivity()
    }
}
