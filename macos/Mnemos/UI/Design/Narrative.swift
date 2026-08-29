import AppKit
import Foundation

/// The single defaults key behind the technical interface. Off means the main
/// window shows understanding only; on brings back counts, confidence, event
/// kinds, and provenance for debugging the engine.
enum DeveloperDetails {
    static let defaultsKey = "showsDeveloperDetails"
}

/// Turns what the engine stores into what a person reads.
///
/// The store keeps deliberately mechanical text — templated digests, raw window
/// titles, action tokens like `"used terminal"` — because search, the agent API,
/// and the MCP tools all index it. Nothing here changes any of that; these are
/// pure functions the views call at render time.
enum Narrative {
    // MARK: - Title

    /// A readable headline for a task: the user's own title untouched, or the
    /// stored title with app-name suffixes and paths stripped away.
    static func title(for task: TaskMemory) -> String {
        let raw = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Untitled" }
        guard !task.isUserLocked else { return raw }

        if let application = raw.remainder(after: "Activity in ") {
            return "Worked in \(application)"
        }
        if let project = raw.remainder(after: "Working on ") {
            return ProjectName.display(project)
        }

        var cleaned = stripApplicationSuffix(raw, applications: task.applications)
        if let name = fileName(cleaned) { cleaned = name }
        return truncate(cleaned, limit: 70)
    }

    // MARK: - Summary

    /// One or two plain sentences describing the task, built from the structured
    /// fields rather than from the stored digest template.
    static func summary(for task: TaskMemory) -> String {
        var sentences: [String] = []

        let verb = verbPhrase(for: task.actions)
        let apps = list(task.applications.prefix(3).map { $0 })
        let project = self.project(for: task).map { " on \($0)" } ?? ""

        if apps.isEmpty {
            sentences.append("\(verb)\(project).")
        } else {
            sentences.append("\(verb) in \(apps)\(project).")
        }

        if let place = lastPlace(for: task) {
            sentences.append("Last on \(place).")
        }

        return sentences.joined(separator: " ")
    }

    /// The quiet caption under a memory: when, which project, which apps.
    static func meta(for task: TaskMemory) -> String {
        var parts = [timeRange(for: task)]
        if let project = project(for: task) {
            parts.append(project)
        }
        let apps = task.applications.prefix(3).joined(separator: " + ")
        if !apps.isEmpty {
            parts.append(apps)
        }
        return parts.joined(separator: " · ")
    }

    /// "12:46 PM – 1:32 PM · 46m", or the running time while a task is open.
    /// Dates outside today are prefixed, since only the list groups by day.
    static func timeRange(for task: TaskMemory) -> String {
        let start = task.startedAt.formatted(date: .omitted, time: .shortened)
        let day = Calendar.current.isDateInToday(task.startedAt)
            ? ""
            : "\(task.startedAt.formatted(date: .abbreviated, time: .omitted)), "

        if task.isOpen {
            return "\(day)since \(start) · \(Elapsed.label(from: task.startedAt))"
        }
        let end = task.endedAt.formatted(date: .omitted, time: .shortened)
        return "\(day)\(start) – \(end) · \(Elapsed.label(from: task.startedAt, to: task.endedAt))"
    }

    /// Where the work stopped, as a file name or a site rather than a raw path.
    /// Returns nil when the stored state is a keystroke or another fragment that
    /// would read as an answer without being one.
    static func lastPlace(for task: TaskMemory) -> String? {
        guard LastState.isMeaningful(task.lastState),
              let state = task.lastState?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let resolved = place(state)
        guard LastState.isMeaningful(resolved) else { return nil }
        return truncate(resolved, limit: 90)
    }

    // MARK: - Activity

    /// One step of the task, as a sentence: "Worked in Xcode on AppModel.swift".
    static func step(for span: ActivitySpan) -> String {
        if let url = span.url, let pretty = site(url) {
            return "Read \(pretty)"
        }
        if let path = span.documentPath, let name = fileName(path) {
            return "Worked in \(span.applicationName) on \(name)"
        }
        let context = span.windowTitle ?? span.anchorKey
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = stripApplicationSuffix(context, applications: [span.applicationName])
            if !cleaned.isEmpty {
                return "Worked in \(span.applicationName) on \(truncate(cleaned, limit: 60))"
            }
        }
        return "Worked in \(span.applicationName)"
    }

    /// A file or link split into what to show and what to reveal on hover.
    static func artifact(_ raw: String) -> (label: String, detail: String) {
        (label: place(raw), detail: raw)
    }

    /// The task's files and links, ready to list: collapsed to one entry per
    /// visible label, and with the entry that only restates the project name
    /// removed, since the project is already shown in the header.
    static func artifacts(for task: TaskMemory, limit: Int = 12) -> [(id: String, label: String, detail: String)] {
        let projectLabel = task.workstream.map { ProjectName.display($0.displayName).lowercased() }
        var seen = Set<String>()
        var items: [(id: String, label: String, detail: String)] = []
        for raw in task.artifacts {
            let item = artifact(raw)
            let key = item.label.lowercased()
            guard !key.isEmpty, key != projectLabel, seen.insert(key).inserted else { continue }
            items.append((id: raw, label: item.label, detail: item.detail))
            if items.count == limit { break }
        }
        return items
    }

    /// The project name as a person should read it.
    static func project(for task: TaskMemory) -> String? {
        task.workstream.map { ProjectName.display($0.displayName) }
    }

    // MARK: - Building blocks

    /// The action tokens the store derives are ordered by how much they say
    /// about the work; the most specific one becomes the sentence's verb.
    private static func verbPhrase(for actions: [String]) -> String {
        let phrases: [(token: String, phrase: String)] = [
            ("used terminal", "Ran commands"),
            ("typed", "Wrote and edited"),
            ("worked with documents", "Opened files"),
            ("browsed", "Read pages"),
            ("selected content", "Reviewed content"),
            ("reviewed changed content", "Reviewed changes"),
        ]
        for phrase in phrases where actions.contains(phrase.token) {
            return phrase.phrase
        }
        return "Worked"
    }

    /// A file name for a path, a site for a link, the text itself otherwise.
    private static func place(_ raw: String) -> String {
        if let site = site(raw) { return site }
        if let name = fileName(raw) { return name }
        return raw
    }

    /// "github.com/samar-58/mnemos" for a web link, nil for anything else.
    private static func site(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let host = components.host,
              let scheme = components.scheme,
              scheme == "http" || scheme == "https" else { return nil }
        let trimmedHost = host.remainder(after: "www.") ?? host
        let path = components.path.split(separator: "/").prefix(2).joined(separator: "/")
        return path.isEmpty ? trimmedHost : "\(trimmedHost)/\(path)"
    }

    /// The last component of something that looks like a file path.
    private static func fileName(_ raw: String) -> String? {
        guard raw.contains("/"), !raw.contains(" ") || raw.hasPrefix("/") || raw.hasPrefix("~") else {
            return nil
        }
        let name = raw.split(separator: "/").last.map(String.init)
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// Drops trailing " — Xcode" style segments that only repeat the app name.
    private static func stripApplicationSuffix(_ raw: String, applications: [String]) -> String {
        let separators = [" — ", " – ", " - ", " | "]
        let known = Set(applications.map { $0.lowercased() })
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        var didStrip = true
        while didStrip {
            didStrip = false
            for separator in separators {
                guard let range = value.range(of: separator, options: .backwards) else { continue }
                let tail = value[range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard known.contains(tail.lowercased()) else { continue }
                value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                didStrip = true
                break
            }
        }
        return value.isEmpty ? raw : value
    }

    /// "Codex and Xcode", "Codex, Xcode, and Ghostty".
    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: "\(items.dropLast().joined(separator: ", ")), and \(items[items.count - 1])"
        }
    }

    /// Truncates on a word boundary so a headline never ends mid-word.
    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let clipped = value.prefix(limit)
        guard let space = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: space) > limit / 2 else {
            return clipped.trimmingCharacters(in: .whitespaces) + "…"
        }
        return clipped[..<space].trimmingCharacters(in: .whitespaces) + "…"
    }
}

private extension String {
    /// What follows `prefix`, or nil when the string does not start with it.
    func remainder(after prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let value = String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// The agent-ready summary of a task, shared by the recall panel and the detail
/// view so both produce exactly the same text.
enum ContextClipboard {
    @MainActor
    static func copy(task: TaskMemory, evidence: [EvidenceItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(task: task, evidence: evidence), forType: .string)
    }

    /// Several episodes of the same work as one block of context, so pasting a
    /// grouped afternoon into an agent reads as an afternoon rather than as six
    /// disconnected fragments. Evidence is attached once at the end because it
    /// was pooled across the group.
    @MainActor
    static func copy(tasks: [TaskMemory], evidence: [EvidenceItem]) {
        guard !tasks.isEmpty else { return }
        guard tasks.count > 1 else { return copy(task: tasks[0], evidence: evidence) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(tasks: tasks, evidence: evidence), forType: .string)
    }

    static func text(tasks: [TaskMemory], evidence: [EvidenceItem]) -> String {
        guard let first = tasks.last, let last = tasks.first else { return "" }
        let heading = Narrative.project(for: last) ?? Narrative.title(for: last)
        var lines = ["# \(heading)"]
        lines.append(
            "\(first.startedAt.formatted(date: .abbreviated, time: .shortened))"
                + " – \(last.endedAt.formatted(date: .omitted, time: .shortened))"
                + " · \(tasks.count) sessions"
        )
        lines.append("")
        for task in tasks {
            lines.append("## \(Narrative.timeRange(for: task))")
            if !task.digest.isEmpty { lines.append(task.digest) }
            if let state = task.lastState, LastState.isMeaningful(state) {
                lines.append("Left off at: \(state)")
            }
            lines.append("")
        }
        let artifacts = Set(tasks.flatMap(\.artifacts)).sorted().prefix(10)
        if !artifacts.isEmpty {
            lines.append("Files and links:")
            lines.append(contentsOf: artifacts.map { "- \($0)" })
            lines.append("")
        }
        let excerpts = evidence.compactMap(\.excerpt).prefix(6)
        if !excerpts.isEmpty {
            lines.append("Evidence:")
            lines.append(contentsOf: excerpts.map { "- \($0)" })
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func text(task: TaskMemory, evidence: [EvidenceItem]) -> String {
        var lines = ["# \(task.title)"]
        lines.append(task.startedAt.formatted(date: .abbreviated, time: .shortened))
        if !task.digest.isEmpty { lines.append(task.digest) }
        if let state = task.lastState, LastState.isMeaningful(state) { lines.append("Left off at: \(state)") }
        if !task.artifacts.isEmpty {
            lines.append("Files and links:")
            lines.append(contentsOf: task.artifacts.prefix(6).map { "- \($0)" })
        }
        let excerpts = evidence.compactMap(\.excerpt).prefix(4)
        if !excerpts.isEmpty {
            lines.append("Evidence:")
            lines.append(contentsOf: excerpts.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
