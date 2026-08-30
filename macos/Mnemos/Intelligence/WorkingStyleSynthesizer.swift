import Foundation

/// Builds the single consolidated working-style skill.
///
/// Earlier skill generation fingerprinted raw event kinds, so it produced a
/// handful of near-duplicate fragments like "Edit Text → Switch Context" that
/// described input mechanics rather than work. This synthesizer stays at the
/// level a person would recognise: the tools they reach for, the projects they
/// work in, the order they move through them, and when. Everything it emits is
/// counted from captured evidence, and anything it cannot observe it says is
/// unobserved instead of guessing.
enum WorkingStyleSynthesizer {
    static let skillID = "skill:working-style"

    /// A role is what an application is *for*. Grouping by role is what lets the
    /// workflow read as "edit, then run, then check" instead of a list of names.
    enum AppRole: String, CaseIterable, Sendable {
        case editor
        case terminal
        case browser
        case assistant
        case communication
        case design
        case notes
        case other

        var label: String {
            switch self {
            case .editor: "Editor"
            case .terminal: "Terminal"
            case .browser: "Browser"
            case .assistant: "AI assistant"
            case .communication: "Communication"
            case .design: "Design"
            case .notes: "Notes"
            case .other: "Other"
            }
        }

        /// How a step reads when this role is the one being used.
        var action: String {
            switch self {
            case .editor: "Edit code"
            case .terminal: "Run commands"
            case .browser: "Look things up and review"
            case .assistant: "Work through the problem"
            case .communication: "Coordinate"
            case .design: "Work on design"
            case .notes: "Capture notes"
            case .other: "Work"
            }
        }
    }

    struct AppUsage: Equatable, Sendable {
        let name: String
        let bundleID: String?
        let observations: Int

        init(name: String, bundleID: String? = nil, observations: Int) {
            self.name = name
            self.bundleID = bundleID
            self.observations = observations
        }
    }

    struct ProjectUsage: Equatable, Sendable {
        let name: String
        let kind: WorkstreamKind
        let episodes: Int
        let lastActiveAt: Date
    }

    struct Input: Equatable, Sendable {
        var apps: [AppUsage] = []
        var projects: [ProjectUsage] = []
        /// Filesystem roots only. Web hosts are tracked separately so the skill
        /// never claims a project "lives under" teams.cloud.microsoft.
        var artifactRoots: [String] = []
        var webSurfaces: [String] = []
        /// Ordered application handoffs observed inside a single episode.
        var transitions: [Transition] = []
        var memoryCount = 0
        var episodeCount = 0
        var dayCount = 0
        var firstActivityAt: Date?
        var lastActivityAt: Date?
        /// Local hour each episode started, used for a typical-hours range.
        var startHours: [Int] = []
        var verificationCommands: [String] = []
        var openLoops: [String] = []
        var evidenceMemoryIDs: [String] = []

        struct Transition: Equatable, Sendable {
            let from: String
            let to: String
            let count: Int
        }
    }

    struct Draft: Equatable, Sendable {
        let title: String
        let description: String
        let trigger: String
        let workflow: [String]
        let preferences: [String]
        let constraints: [String]
        let verification: [String]
        let evidenceMemoryIDs: [String]
        let confidence: Double
        let occurrenceCount: Int

        /// Every field that a reader would notice changing, so an unchanged
        /// day of capture does not churn out a pointless new version.
        var contentSignature: String {
            ([title, description, trigger]
                + workflow + preferences + constraints + verification).joined(separator: "|")
        }
    }

    /// Not enough captured work to say anything honest about how someone works.
    static let minimumEpisodes = 3

    static func synthesize(_ input: Input, now: Date = .now, calendar: Calendar = .current) -> Draft? {
        guard input.episodeCount >= minimumEpisodes, !input.apps.isEmpty else { return nil }

        let ranked = mergeDuplicates(input.apps).sorted { $0.observations > $1.observations }
        let roles = rolesByUsage(ranked)
        // A website bucket is a place, not a project to default to.
        let projects = input.projects
            .filter { $0.kind == .gitRepository || $0.kind == .localProject || $0.kind == .custom }
            .sorted { $0.episodes == $1.episodes ? $0.lastActiveAt > $1.lastActiveAt : $0.episodes > $1.episodes }

        return Draft(
            title: "How this Mac is actually used for work",
            description: describe(input: input, ranked: ranked, projects: projects),
            trigger: "When helping with work on this Mac — before choosing tools, picking a project, "
                + "or deciding where to resume.",
            workflow: workflow(input: input, ranked: ranked, roles: roles, projects: projects),
            preferences: preferences(roles: roles, ranked: ranked),
            constraints: constraints(input: input, projects: projects, calendar: calendar),
            verification: verification(input: input),
            evidenceMemoryIDs: input.evidenceMemoryIDs,
            confidence: confidence(input: input),
            occurrenceCount: input.episodeCount
        )
    }

    // MARK: - Sections

    private static func describe(
        input: Input, ranked: [AppUsage], projects: [ProjectUsage]
    ) -> String {
        var parts = [
            "Derived from \(input.episodeCount) captured work episode\(input.episodeCount == 1 ? "" : "s")"
                + (input.dayCount > 0 ? " across \(input.dayCount) day\(input.dayCount == 1 ? "" : "s")" : "")
                + ".",
        ]
        let working = ranked.filter { !isUtilitySurface($0.name) }
        if let top = working.first {
            let others = working.dropFirst().prefix(3).map(\.name)
            parts.append(others.isEmpty
                ? "Work centres on \(top.name)."
                : "Work centres on \(top.name), with \(list(Array(others))).")
        }
        if let leadProject = projects.first {
            parts.append("The most active project is \(leadProject.name).")
        }
        return parts.joined(separator: " ")
    }

    /// The workflow follows the busiest observed handoff chain, so it reflects
    /// the order applications were actually used rather than an assumed one.
    private static func workflow(
        input: Input, ranked: [AppUsage], roles: [AppRole: [AppUsage]], projects: [ProjectUsage]
    ) -> [String] {
        var steps: [String] = []
        let working = ranked.filter { !isUtilitySurface($0.name) }
        let chain = dominantChain(transitions: input.transitions, ranked: working)
            .filter { !isUtilitySurface($0) }
        if chain.count >= 2 {
            for (index, app) in chain.enumerated() {
                let role = role(for: app, in: roles)
                steps.append("\(index + 1). \(role.action) in \(app)\(roleSuffix(role))")
            }
        } else {
            // Without a repeated handoff the honest statement is volume, not order.
            for (index, app) in working.prefix(4).enumerated() {
                let role = role(for: app.name, in: roles)
                steps.append("\(index + 1). \(role.action) in \(app.name)\(roleSuffix(role))")
            }
        }
        if let leadProject = projects.first {
            let names = projects.prefix(4).map(\.name)
            steps.append("Work happens in \(list(names))"
                + (projects.count > names.count ? ", among others." : ".")
                + " Default to \(leadProject.name) when a project is not named.")
        }
        if !input.openLoops.isEmpty {
            steps.append("Pick up an open thread before starting something new: "
                + list(Array(input.openLoops.prefix(3))) + ".")
        }
        return steps
    }

    private static func preferences(roles: [AppRole: [AppUsage]], ranked: [AppUsage]) -> [String] {
        var result: [String] = []
        for role in AppRole.allCases where role != .other {
            guard let apps = roles[role], let leading = apps.max(by: { $0.observations < $1.observations })
            else { continue }
            let alternatives = apps.filter { $0.name != leading.name }.map(\.name)
            result.append("\(role.label): \(leading.name)"
                + (alternatives.isEmpty ? "" : " (also \(list(alternatives)))"))
        }
        if result.isEmpty, let top = ranked.first { result.append("Main application: \(top.name)") }
        return result
    }

    private static func constraints(
        input: Input, projects: [ProjectUsage], calendar: Calendar
    ) -> [String] {
        var result: [String] = []
        if !input.artifactRoots.isEmpty {
            result.append("Project files live under \(list(input.artifactRoots.prefix(3).map { $0 })).")
        }
        if !input.webSurfaces.isEmpty {
            result.append("Frequently used web surfaces: \(list(input.webSurfaces.prefix(4).map { $0 })).")
        }
        if let hours = typicalHours(input.startHours) {
            result.append("Most work starts between \(hour(hours.lowerBound)) and \(hour(hours.upperBound)) local time.")
        } else {
            // Work spread right across the day has no honest window, but the
            // hours it concentrates in are still worth knowing.
            let busiest = busiestHours(input.startHours)
            if !busiest.isEmpty {
                result.append("Work is spread across the day; it concentrates around "
                    + list(busiest.map(hour)) + " local time.")
            }
        }
        if let last = input.lastActivityAt {
            result.append("The most recent captured activity is "
                + last.formatted(date: .abbreviated, time: .shortened) + ".")
        }
        let repositories = projects.filter { $0.kind == .gitRepository }.map(\.name)
        if !repositories.isEmpty {
            result.append("Git repositories in active use: \(list(Array(repositories.prefix(5)))).")
        }
        result.append("This describes observed habits, not instructions the user has given. "
            + "Confirm before acting on anything consequential.")
        return result
    }

    private static func verification(input: Input) -> [String] {
        guard !input.verificationCommands.isEmpty else {
            return [
                "No verification step has been observed in captured activity yet. "
                    + "Do not assume tests are run — ask what should be checked.",
            ]
        }
        return input.verificationCommands.prefix(4).map { "Observed check: \($0)" }
    }

    private static func confidence(input: Input) -> Double {
        let volume = min(1.0, Double(input.episodeCount) / 40.0)
        let spread = min(1.0, Double(input.dayCount) / 5.0)
        return min(0.95, 0.4 + 0.35 * volume + 0.2 * spread)
    }

    /// The middle of the working day. A raw min–max is worthless once a single
    /// late night stretches it to "12 AM–11 PM", so trim to the 10th–90th
    /// percentile and stay quiet when the spread still says nothing.
    static func typicalHours(_ hours: [Int]) -> ClosedRange<Int>? {
        guard hours.count >= 5 else { return nil }
        let sorted = hours.sorted()
        // Trim a symmetric tenth off each end, so one midnight session cannot
        // define the working day.
        let trim = sorted.count / 10
        let low = sorted[trim]
        let high = sorted[sorted.count - 1 - trim]
        guard high >= low, high - low <= 14 else { return nil }
        return low...high
    }

    /// The hours work actually clusters in, used when the spread is too wide
    /// for a single window to mean anything.
    static func busiestHours(_ hours: [Int], count: Int = 3) -> [Int] {
        guard hours.count >= 5 else { return [] }
        var counts: [Int: Int] = [:]
        for hour in hours { counts[hour, default: 0] += 1 }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(count).map(\.key).sorted()
    }

    /// Application names arrive with invisible direction marks and stray
    /// whitespace, which otherwise reads as "WhatsApp (also ‎WhatsApp)".
    static func normalizeAppName(_ name: String) -> String {
        String(name.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergeDuplicates(_ apps: [AppUsage]) -> [AppUsage] {
        var merged: [String: AppUsage] = [:]
        for app in apps {
            let name = normalizeAppName(app.name)
            guard !name.isEmpty else { continue }
            if let existing = merged[name.lowercased()] {
                merged[name.lowercased()] = AppUsage(
                    name: existing.name, bundleID: existing.bundleID ?? app.bundleID,
                    observations: existing.observations + app.observations
                )
            } else {
                merged[name.lowercased()] = AppUsage(
                    name: name, bundleID: app.bundleID, observations: app.observations
                )
            }
        }
        return Array(merged.values)
    }

    /// System and file-management surfaces are passed through, not worked in.
    static func isUtilitySurface(_ name: String) -> Bool {
        let text = name.lowercased()
        return ["system settings", "system preferences", "finder", "activity monitor",
                "installer", "dock", "spotlight", "loginwindow", "notification centre",
                "notification center", "control centre", "control center", "macos"]
            .contains { text == $0 || text.hasPrefix($0) }
    }

    // MARK: - Ordering

    /// Walks the most frequent handoffs into a chain, never revisiting an
    /// application, so a busy two-way flip does not become an endless loop.
    static func dominantChain(transitions: [Input.Transition], ranked: [AppUsage]) -> [String] {
        guard !transitions.isEmpty else { return [] }
        var outgoing: [String: [Input.Transition]] = [:]
        for transition in transitions where transition.from != transition.to {
            outgoing[transition.from, default: []].append(transition)
        }
        guard let start = ranked.first(where: { outgoing[$0.name] != nil })?.name else { return [] }
        var chain = [start]
        var visited: Set<String> = [start]
        while chain.count < 5, let options = outgoing[chain[chain.count - 1]] {
            let next = options
                .filter { !visited.contains($0.to) }
                .max { lhs, rhs in
                    lhs.count == rhs.count ? lhs.to > rhs.to : lhs.count < rhs.count
                }
            guard let next else { break }
            chain.append(next.to)
            visited.insert(next.to)
        }
        return chain.count >= 2 ? chain : []
    }

    // MARK: - Roles

    static func role(for application: String, bundleID: String? = nil) -> AppRole {
        let name = application.lowercased()
        let bundle = (bundleID ?? "").lowercased()
        func matches(_ needles: [String]) -> Bool {
            needles.contains { name.contains($0) || bundle.contains($0) }
        }
        if matches(["cursor", "xcode", "visual studio code", "vscode", "zed", "sublime",
                    "intellij", "pycharm", "webstorm", "android studio", "nova", "textmate"]) {
            return .editor
        }
        if matches(["ghostty", "iterm", "terminal", "warp", "alacritty", "kitty", "hyper", "tmux"]) {
            return .terminal
        }
        if matches(["chrome", "safari", "firefox", "arc", "microsoft edge", "brave", "orion"]) {
            return .browser
        }
        if matches(["chatgpt", "claude", "perplexity", "copilot", "gemini"]) { return .assistant }
        if matches(["slack", "whatsapp", "teams", "discord", "zoom", "mail", "telegram",
                    "messages", "outlook"]) {
            return .communication
        }
        if matches(["figma", "sketch", "affinity", "photoshop", "illustrator"]) { return .design }
        if matches(["notion", "obsidian", "bear", "craft", "notes"]) { return .notes }
        return .other
    }

    private static func rolesByUsage(_ apps: [AppUsage]) -> [AppRole: [AppUsage]] {
        var result: [AppRole: [AppUsage]] = [:]
        for app in apps {
            result[role(for: app.name, bundleID: app.bundleID), default: []].append(app)
        }
        return result
    }

    private static func role(for application: String, in roles: [AppRole: [AppUsage]]) -> AppRole {
        for (role, apps) in roles where apps.contains(where: { $0.name == application }) { return role }
        return .other
    }

    /// "AI assistant" keeps its capitals; the rest read better lowercased.
    private static func roleSuffix(_ role: AppRole) -> String {
        switch role {
        case .other: "."
        case .assistant: " (\(role.label))."
        default: " (\(role.label.lowercased()))."
        }
    }

    // MARK: - Formatting

    private static func list(_ values: some Collection<String>) -> String {
        let items = Array(values)
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    private static func hour(_ value: Int) -> String {
        guard let date = Calendar.current.date(from: DateComponents(
            year: 2_000, month: 1, day: 1, hour: value, minute: 0
        )) else { return "\(value):00" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
