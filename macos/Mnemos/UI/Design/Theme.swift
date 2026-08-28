import SwiftUI

/// The one spacing scale. Every gap in the app is one of these values.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radius {
    static let chip: CGFloat = 6
    static let container: CGFloat = 10
}

/// One SF Symbol per concept, chosen once so the same idea never appears
/// under two different glyphs.
enum Glyph {
    static let recent = "clock"
    static let today = "sun.max"
    static let pinned = "pin.fill"
    static let unpinned = "pin"
    static let workstream = "point.3.connected.trianglepath.dotted"
    static let task = "checklist"
    static let evidence = "text.quote"
    static let span = "rectangle.stack"
    static let live = "record.circle"
    static let application = "app"
    static let browser = "globe"
    static let document = "doc"
    static let terminal = "terminal"
    static let search = "magnifyingglass"
    static let inspector = "sidebar.trailing"
    static let agents = "cpu"
    static let intelligence = "sparkles"
    static let privacy = "hand.raised"
    static let capture = "dot.radiowaves.left.and.right"
    static let storage = "internaldrive"
    static let advanced = "wrench.and.screwdriver"
    static let general = "gearshape"
    static let pause = "pause.fill"
    static let resume = "play.fill"
}

extension WorkstreamKind {
    var glyph: String {
        switch self {
        case .gitRepository: "arrow.triangle.branch"
        case .localProject: "folder"
        case .website: Glyph.browser
        case .conversation: "bubble.left.and.bubble.right"
        case .custom: "square.stack"
        }
    }

    var label: String {
        switch self {
        case .gitRepository: "Repository"
        case .localProject: "Project"
        case .website: "Website"
        case .conversation: "Conversation"
        case .custom: "Custom"
        }
    }
}

extension AppModel.CaptureStatus {
    /// Status is always a dot plus a label — never colour alone.
    var tint: Color {
        switch self {
        case .running: .green
        case .ready: .secondary
        case .paused: .secondary
        case .permissionRequired: .orange
        }
    }

    var glyph: String {
        switch self {
        case .running: Glyph.live
        case .ready: "circle.dotted"
        case .paused: "pause.circle"
        case .permissionRequired: "exclamationmark.triangle"
        }
    }
}

extension AgentAPIStatus {
    var tint: Color {
        switch self {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

/// Plain-language names for the capture kinds stored with each observation.
/// The raw values stay in the database and the agent API; only the UI softens
/// them.
enum EventKindLabel {
    static func label(for raw: String) -> String {
        switch raw {
        case CapturedEvent.Kind.application.rawValue: "App switch"
        case CapturedEvent.Kind.keyboard.rawValue: "Typing"
        case CapturedEvent.Kind.mouse.rawValue: "Click"
        case CapturedEvent.Kind.browser.rawValue: "Web page"
        case CapturedEvent.Kind.axSnapshot.rawValue: "Screen context"
        case CapturedEvent.Kind.axDiff.rawValue: "Screen change"
        default: raw
        }
    }
}

extension EvidenceSource {
    var label: String {
        switch self {
        case .raw: "Recorded activity"
        case .compacted: "Saved context"
        case .userSelected: "Saved by you"
        }
    }
}

/// Day headings for the task list: Today, Yesterday, weekday inside the last
/// week, then an explicit date.
enum DayHeading {
    static func label(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).year())
    }
}

enum Elapsed {
    /// Compact "4m", "1h 12m" style duration.
    static func label(from start: Date, to end: Date = .now) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let minutes = seconds / 60
        guard minutes >= 60 else { return "\(max(minutes, 1))m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }
}
