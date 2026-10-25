import SwiftUI
import WidgetKit
import ActivityKit

/// The app's accent (Settings > Appearance), which the app sends with each update; before it does, Telegram's pink.
private let defaultAccent: UInt32 = 0xEB6CA4

extension TauActivityAttributes.ContentState {
    /// On the activity's dark background: black, Day's darkest accent, would vanish, so it shows as white.
    var accentValue: UInt32 {
        let value = self.accent ?? defaultAccent
        let r = Double((value >> 16) & 0xff), g = Double((value >> 8) & 0xff), b = Double(value & 0xff)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 40.0 ? 0xFFFFFF : value
    }
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue: UInt32 = defaultAccent
}

extension EnvironmentValues {
    var tauAccent: UInt32 {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

/// The accent, and a lighter one for the top of the working ring's gradient.
private func tauAccentTint(_ value: UInt32) -> Color {
    return rgb(value)
}

private func tauAccentLight(_ value: UInt32) -> Color {
    let mix = { (channel: UInt32) -> Double in
        let c = Double(channel & 0xff) / 255.0
        return c + (1.0 - c) * 0.35
    }
    return Color(red: mix(value >> 16), green: mix(value >> 8), blue: mix(value))
}
private let failedRed = Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)

private func rgb(_ value: UInt32) -> Color {
    return Color(red: Double((value >> 16) & 0xff) / 255.0, green: Double((value >> 8) & 0xff) / 255.0, blue: Double(value & 0xff) / 255.0)
}

/// Telegram's avatar gradients (bottom, top), in the order the app's Avatar picks them by chat ID, so a chat has the
/// colors it has in the list.
private let avatarGradients: [(UInt32, UInt32)] = [(0xFF516A, 0xFF885E), (0xFFA85C, 0xFFCD6A), (0x665FFF, 0x82B1FF), (0x54CB68, 0xA0DE7E), (0x4ACCCD, 0x00FCFD), (0x2A9EF1, 0x72D5FD), (0xD669ED, 0xE0A2F3)]

private func avatarLetters(_ title: String) -> String {
    let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
    let initials = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
    return initials.isEmpty ? "?" : initials.joined()
}

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

/// How long a chat has worked, in whole minutes as of the last update, never seconds (docs/live-activity.md).
func minutesText(_ minutes: Int, compact: Bool = false) -> String {
    if compact {
        return minutes < 1 ? "<1m" : minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    } else if minutes < 1 {
        return "<1 min"
    } else if minutes < 60 {
        return "\(minutes) min"
    }
    return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
}

private extension TauActivityAttributes.ContentState {
    var working: [TauActivityAttributes.Chat] {
        return self.chats.filter { $0.state == .working }
    }

    var hasFailed: Bool {
        return self.chats.contains { $0.state == .failed }
    }

    /// The chats beyond the two the rows show.
    var hidden: Int {
        return self.more + max(0, self.chats.count - 2)
    }

    /// What the island's top line says: how many are working, else whether they are done.
    var headline: String {
        let working = self.working.count
        if working == 1 && self.chats.count == 1 {
            return "Working"
        } else if working > 0 {
            return "\(working) working"
        }
        return self.hasFailed ? "Failed" : "Done"
    }
}

/// A chat's avatar as in the list (Telegram's letters and gradient); working, a pink ring around it, as a story's;
/// done, a pink check on it; failed, a red mark. The ring's room is always kept, so rows line up whatever their state.
struct ChatAvatar: View {
    let chat: TauActivityAttributes.Chat
    let diameter: CGFloat
    let isStale: Bool
    @Environment(\.tauAccent) private var accent

    var body: some View {
        let (bottom, top) = avatarGradients[abs(self.chat.id) % avatarGradients.count]
        let ring: CGFloat = self.diameter > 36.0 ? 2.0 : 1.5
        let gap: CGFloat = self.diameter > 36.0 ? 2.5 : 2.0
        let badge = floor(self.diameter * 0.42)
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [rgb(top), rgb(bottom)], startPoint: .top, endPoint: .bottom))
            Text(avatarLetters(self.chat.title))
                .font(.system(size: floor(self.diameter * 26.0 / 60.0), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
        }
        .frame(width: self.diameter, height: self.diameter)
        .padding(ring + gap)
        .overlay {
            if self.chat.state == .working {
                Circle()
                    .strokeBorder(LinearGradient(colors: [tauAccentLight(self.accent), tauAccentTint(self.accent)], startPoint: .top, endPoint: .bottom), lineWidth: ring)
                    .opacity(self.isStale ? 0.4 : 1.0)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if self.chat.state != .working {
                Image(systemName: self.chat.state == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: badge, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, self.chat.state == .done ? tauAccentTint(self.accent) : failedRed)
                    .background(Circle().fill(Color(red: 0.07, green: 0.07, blue: 0.08)).padding(-1.5))
            }
        }
    }
}

/// The end of a chat's title line: its minutes while it works (when it began, once updates have stopped), Done or
/// Failed after.
struct ChatStateLabel: View {
    let chat: TauActivityAttributes.Chat
    let isStale: Bool
    @Environment(\.tauAccent) private var accent

    var body: some View {
        switch self.chat.state {
        case .working:
            Text(self.isStale ? "since \(self.chat.since.formatted(date: .omitted, time: .shortened))" : minutesText(self.chat.minutes))
                .foregroundStyle(tauAccentTint(self.accent))
        case .done:
            Text("Done")
                .foregroundStyle(tauAccentTint(self.accent))
        case .failed:
            Text("Failed")
                .foregroundStyle(failedRed)
        }
    }
}

/// A chat: the avatar, then the title and its state on one line, the step or the answer's first line under it.
struct ChatRow: View {
    let chat: TauActivityAttributes.Chat
    let isStale: Bool
    var diameter: CGFloat = 40.0
    /// Off in the island with one chat: its top line says it already.
    var showsState = true

    var body: some View {
        HStack(alignment: .center, spacing: 10.0) {
            ChatAvatar(chat: self.chat, diameter: self.diameter, isStale: self.isStale)
            VStack(alignment: .leading, spacing: 1.0) {
                HStack(alignment: .firstTextBaseline, spacing: 8.0) {
                    Text(self.chat.title)
                        .font(.system(size: 15.0, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0.0)
                    if self.showsState {
                        ChatStateLabel(chat: self.chat, isStale: self.isStale)
                            .font(.system(size: 13.0, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                Text(self.detail)
                    .font(.system(size: 14.0))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var detail: String {
        if self.chat.state == .working {
            return self.isStale ? "Open tau for the latest" : (self.chat.detail ?? "Working")
        }
        return self.chat.detail ?? (self.chat.state == .done ? "Answered" : "The model failed")
    }
}

/// The rows, linked to their chats when there are several (one chat: the whole card or island opens it), and how many
/// more there are under them, in line with the titles. Two at most: the island and the lock screen give an activity
/// 160 pt.
struct ChatRows: View {
    let state: TauActivityAttributes.ContentState
    let isStale: Bool
    let diameter: CGFloat
    let spacing: CGFloat
    var island = false

    var body: some View {
        VStack(alignment: .leading, spacing: self.spacing) {
            ForEach(self.state.chats.prefix(2), id: \.id) { chat in
                if self.state.chats.count > 1, let url = chat.url {
                    Link(destination: url) {
                        ChatRow(chat: chat, isStale: self.isStale, diameter: self.diameter)
                    }
                } else {
                    ChatRow(chat: chat, isStale: self.isStale, diameter: self.diameter, showsState: !self.island)
                }
            }
            if !self.island && self.state.hidden > 0 {
                Text("+\(self.state.hidden) more")
                    .font(.system(size: 13.0, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, self.diameter + (self.diameter > 36.0 ? 9.0 : 7.0) + 10.0)
            }
        }
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<TauActivityAttributes>

    var body: some View {
        ChatRows(state: self.context.state, isStale: self.context.isStale, diameter: 38.0, spacing: 10.0)
            .padding(.horizontal, 14.0)
            .padding(.vertical, 12.0)
            // Dark, as the island: the pinks and the avatars read the same on both.
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.82))
            .activitySystemActionForegroundColor(tauAccentTint(self.context.state.accentValue))
            .environment(\.tauAccent, self.context.state.accentValue)
            .widgetURL(self.context.state.chats.count == 1 ? self.context.state.chats[0].url : nil)
    }
}

/// The island's right side when compact: one chat's minutes; several working, how many, in a pink disc; all done, a
/// pink check; one failed, a red mark.
struct CompactTrailing: View {
    let state: TauActivityAttributes.ContentState
    let isStale: Bool
    @Environment(\.tauAccent) private var accent

    var body: some View {
        let working = self.state.working
        if working.count > 1 {
            Text("\(working.count)")
                .font(.system(size: 13.0, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
                .frame(minWidth: 20.0, minHeight: 20.0)
                .background(Capsule().fill(tauAccentTint(self.accent)))
        } else if let chat = working.first {
            if self.isStale {
                Image(systemName: "hourglass")
                    .font(.system(size: 15.0, weight: .semibold))
                    .foregroundStyle(tauAccentTint(self.accent))
            } else {
                Text(minutesText(chat.minutes, compact: true))
                    .font(.system(size: 15.0, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tauAccentTint(self.accent))
            }
        } else {
            StateMark(failed: self.state.hasFailed, size: 20.0)
        }
    }
}

/// Done, or failed: a check on a pink disc, or a mark on a red one.
struct StateMark: View {
    let failed: Bool
    let size: CGFloat
    @Environment(\.tauAccent) private var accent

    var body: some View {
        Image(systemName: self.failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.system(size: self.size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.black, self.failed ? failedRed : tauAccentTint(self.accent))
    }
}

struct TauLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TauActivityAttributes.self) { context in
            ActivityFamilyView(context: context)
        } dynamicIsland: { context in
            let accent = context.state.accentValue
            let tint = tauAccentTint(accent)
            return DynamicIsland {
                // The top line, either side of the camera: the τ and what is going on; how long, or the check.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6.0) {
                        TauGlyph()
                            .fill(tint)
                            .frame(width: 18.0, height: 18.0)
                        Text(context.state.headline)
                            .font(.system(size: 15.0, weight: .semibold))
                            .foregroundStyle(context.state.working.isEmpty && context.state.hasFailed ? failedRed : tint)
                            .lineLimit(1)
                    }
                    .padding(.leading, 6.0)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .environment(\.tauAccent, accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if context.state.hidden > 0 {
                            Text("+\(context.state.hidden) more")
                                .font(.system(size: 15.0, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else if context.state.working.isEmpty {
                            StateMark(failed: context.state.hasFailed, size: 20.0)
                        } else if context.state.chats.count == 1, let chat = context.state.chats.first {
                            ChatStateLabel(chat: chat, isStale: context.isStale)
                                .font(.system(size: 15.0, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(tint)
                        }
                    }
                    .padding(.trailing, 6.0)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .environment(\.tauAccent, accent)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ChatRows(state: context.state, isStale: context.isStale, diameter: 36.0, spacing: 10.0, island: true)
                        .padding(.horizontal, 6.0)
                        .padding(.top, 6.0)
                        .environment(\.tauAccent, accent)
                }
            } compactLeading: {
                TauGlyph()
                    .fill(tint)
                    .frame(width: 20.0, height: 20.0)
                    .padding(.leading, 2.0)
            } compactTrailing: {
                CompactTrailing(state: context.state, isStale: context.isStale)
                    .padding(.trailing, 2.0)
                    .environment(\.tauAccent, accent)
            } minimal: {
                Group {
                    if context.state.working.isEmpty {
                        StateMark(failed: context.state.hasFailed, size: 20.0)
                    } else {
                        TauGlyph()
                            .fill(tint)
                            .frame(width: 18.0, height: 18.0)
                    }
                }
                .environment(\.tauAccent, accent)
            }
            .widgetURL(context.state.chats.count == 1 ? context.state.chats[0].url : nil)
            .keylineTint(tint)
        }
        // The watch's Smart Stack shows the compact island without it (iOS 18: this extension's deployment target).
        .supplementalActivityFamilies([.small])
    }
}

/// The lock screen, or the watch.
struct ActivityFamilyView: View {
    let context: ActivityViewContext<TauActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch self.family {
        case .small:
            WatchView(context: self.context)
        default:
            LockScreenView(context: self.context)
        }
    }
}

/// The watch (docs/live-activity.md, "Apple Watch"): the newest chat, its avatar saying its state, its title with its
/// minutes while it works, and the step or the start of the answer; with several chats, how many work over it.
struct WatchView: View {
    let context: ActivityViewContext<TauActivityAttributes>

    var body: some View {
        let state = self.context.state
        let accent = state.accentValue
        let others = state.chats.count + state.more - 1
        VStack(alignment: .leading, spacing: 4.0) {
            if others > 0 {
                HStack(spacing: 4.0) {
                    Text(state.headline)
                        .font(.system(size: 12.0, weight: .semibold))
                        .foregroundStyle(!state.working.isEmpty ? tauAccentTint(accent) : state.hasFailed ? failedRed : .secondary)
                    Spacer(minLength: 2.0)
                    Text("+\(others)")
                        .font(.system(size: 12.0, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            if let chat = state.chats.first {
                HStack(alignment: .top, spacing: 7.0) {
                    ChatAvatar(chat: chat, diameter: 24.0, isStale: self.context.isStale)
                    VStack(alignment: .leading, spacing: 1.0) {
                        HStack(alignment: .firstTextBaseline, spacing: 4.0) {
                            Text(chat.title)
                                .font(.system(size: 14.0, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0.0)
                            if chat.state == .working && !self.context.isStale {
                                Text(minutesText(chat.minutes, compact: true))
                                    .font(.system(size: 12.0, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(tauAccentTint(accent))
                                    .layoutPriority(1)
                            }
                        }
                        Text(self.detail(chat))
                            .font(.system(size: 13.0))
                            .foregroundStyle(.secondary)
                            .lineLimit(others > 0 ? 1 : 2)
                    }
                }
            }
        }
        .padding(8.0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .environment(\.tauAccent, accent)
        .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.82))
    }

    private func detail(_ chat: TauActivityAttributes.Chat) -> String {
        if chat.state == .working {
            return self.context.isStale ? "Open tau for the latest" : (chat.detail ?? "Working")
        }
        return chat.detail ?? (chat.state == .done ? "Answered" : "The model failed")
    }
}

@main
struct TauWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TauLiveActivity()
    }
}
