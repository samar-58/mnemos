import SwiftUI

/// The one spacing scale. Every gap in the app is one of these values.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let chip: CGFloat = 5
    static let control: CGFloat = 7
    static let container: CGFloat = 10
    static let card: CGFloat = 12
}

/// The type scale, named by role rather than by size, so a heading never gets
/// picked because it "looked about right" in one view.
enum TypeScale {
    /// The single largest thing on a screen — the detail view's task title.
    static let display = Font.system(size: 22, weight: .semibold, design: .default)
    /// Section titles inside a scroll view.
    static let section = Font.system(size: 11, weight: .semibold, design: .default)
    /// A list row's primary line.
    static let rowTitle = Font.system(size: 13, weight: .semibold, design: .default)
    /// A list row's supporting line.
    static let rowBody = Font.system(size: 12, weight: .regular, design: .default)
    /// Timestamps, durations, counts — anything that should stay column-aligned.
    static let numeric = Font.system(size: 11, weight: .regular, design: .default).monospacedDigit()
    /// The quietest line in a row.
    static let meta = Font.system(size: 11, weight: .regular, design: .default)
    /// Body copy in the detail pane.
    static let prose = Font.system(size: 13, weight: .regular, design: .default)
}

/// Background fills, so "a slightly grey box" is defined once.
enum Surface {
    /// A raised card inside a scrolling pane.
    static let card = AnyShapeStyle(.quaternary.opacity(0.34))
    /// A pressed or hovered row.
    static let hover = AnyShapeStyle(.quaternary.opacity(0.5))
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
    static let settings = "gearshape"
    static let patterns = "point.3.filled.connected.trianglepath.dotted"
    static let skills = "wand.and.stars"
    static let sessions = "square.stack.3d.up"
    static let expand = "chevron.right"
}

/// Workstream names are derived from paths and URLs, so the raw value is often
/// a fragment that means nothing to a person — `partner?expand=1`, a bare
/// `https:`, a mail message id, a numeric path segment. The sidebar shows a
/// tidied name and hides the ones that carry no information at all.
enum ProjectName {
    /// A readable label: query strings dropped, separators normalised, the
    /// leftovers of a URL removed.
    static func display(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let question = value.firstIndex(of: "?") { value = String(value[..<question]) }
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/:-_ "))
        value = value.replacingOccurrences(of: "%20", with: " ")
        return value.isEmpty ? raw : value
    }

    /// False for names that are pure machinery. These still exist in the store
    /// and still group their tasks; they simply do not earn a sidebar row.
    static func isMeaningful(_ raw: String) -> Bool {
        let value = display(raw)
        guard value.count >= 2, value.count <= 60 else { return false }
        // Numbers alone ("65") say nothing about what was worked on.
        if value.allSatisfy(\.isNumber) { return false }
        // Protocol fragments left behind when a URL was parsed as a path.
        if ["http", "https", "file", "www", "about", "localhost"].contains(value.lowercased()) { return false }
        // Opaque identifiers — mail message ids, tokens — are long runs of
        // mixed case and digits with no separator to read them by.
        if value.count >= 16, !value.contains(where: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }) {
            let digits = value.filter(\.isNumber).count
            let uppercase = value.filter(\.isUppercase).count
            if digits > 0, uppercase > 0, digits + uppercase > value.count / 3 { return false }
        }
        return true
    }
}

/// "Where you left off" is only worth a heading when it points somewhere. A
/// bare keystroke like `⌘W`, or a one-word window fragment, is noise dressed up
/// as an answer.
enum LastState {
    private static let noise: Set<String> = [
        "untitled", "new tab", "unknown", "none", "loading", "…", "-", "—",
    ]

    static func isMeaningful(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        guard value.count >= 4 else { return false }
        if noise.contains(value.lowercased()) { return false }
        // Keyboard shortcuts captured as state: ⌘W, ⌃⌥⇧K, and so on.
        let modifiers = CharacterSet(charactersIn: "⌘⌥⌃⇧⇪↩⌫⎋⇥")
        if value.unicodeScalars.contains(where: modifiers.contains),
           value.count <= 6 {
            return false
        }
        // A value with no letters at all is punctuation or a lone number.
        guard value.contains(where: { $0.isLetter }) else { return false }
        return true
    }
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
        label(seconds: end.timeIntervalSince(start))
    }

    static func label(seconds interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval)) / 60
        guard minutes >= 60 else { return "\(max(minutes, 1))m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }
}
