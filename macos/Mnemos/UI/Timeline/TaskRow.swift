import SwiftUI

/// A memory as a list row: an icon, what you did, and when. Counts and
/// confidence stay behind developer details.
struct TaskRow: View {
    let task: TaskMemory
    let result: ContextSearchResult?
    /// Child rows sit under a group header and drop the icon rail, so the
    /// episodes read as a sequence rather than as six more list items.
    var isNested = false

    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false

    private var glyph: String {
        task.workstream?.kind.glyph ?? Glyph.task
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            if isNested {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
                    .padding(.vertical, 1)
                    .accessibilityHidden(true)
            } else {
                RowIcon(systemImage: glyph, isActive: task.isOpen)
            }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    if task.isPinned {
                        Image(systemName: Glyph.pinned)
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Pinned")
                    }
                    Text(isNested ? Narrative.timeRange(for: task) : Narrative.title(for: task))
                        .font(isNested ? TypeScale.numeric : TypeScale.rowTitle)
                        .foregroundStyle(isNested ? .secondary : .primary)
                        .lineLimit(1)
                    if task.isOpen {
                        LiveBadge()
                    }
                    Spacer(minLength: Spacing.s)
                    if !isNested {
                        Text(task.endedAt, format: .dateTime.hour().minute())
                            .font(TypeScale.numeric)
                            .foregroundStyle(.secondary)
                    }
                }

                if let highlight = result?.highlights.first {
                    HighlightedSnippet(snippet: highlight)
                } else {
                    Text(Narrative.summary(for: task))
                        .font(TypeScale.rowBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !isNested {
                    HStack(spacing: Spacing.s) {
                        Text(Narrative.meta(for: task))
                            .font(TypeScale.meta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        if showsDeveloperDetails {
                            MetaLabel(text: "\(task.eventCount)", symbol: Glyph.evidence)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [Narrative.title(for: task)]
        if task.isPinned { parts.append("pinned") }
        if task.isOpen { parts.append("in progress") }
        parts.append(Narrative.summary(for: task))
        parts.append(task.endedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The header of a rolled-up entry: one project, one day, however many episodes
/// the segmenter produced. Clicking it selects the whole group; the chevron
/// opens the episodes underneath.
struct TimelineGroupRow: View {
    let entry: TimelineGroup
    let isExpanded: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    @State private var isHovering = false

    private var title: String {
        Narrative.project(for: entry.lead) ?? Narrative.title(for: entry.lead)
    }

    private var subtitle: String {
        var parts = ["\(entry.tasks.count) sessions", Elapsed.label(seconds: entry.activeSeconds)]
        let applications = entry.applications.prefix(3).joined(separator: " + ")
        if !applications.isEmpty { parts.append(applications) }
        return parts.joined(separator: " · ")
    }

    private var timeRange: String {
        let start = entry.startedAt.formatted(date: .omitted, time: .shortened)
        let end = entry.endedAt.formatted(date: .omitted, time: .shortened)
        return entry.isOpen ? "since \(start)" : "\(start) – \(end)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Button(action: onToggle) {
                Image(systemName: Glyph.expand)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")

            RowIcon(systemImage: entry.lead.workstream?.kind.glyph ?? Glyph.sessions, isActive: entry.isOpen)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    if entry.isPinned {
                        Image(systemName: Glyph.pinned)
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(TypeScale.rowTitle)
                        .lineLimit(1)
                    if entry.isOpen { LiveBadge() }
                    Spacer(minLength: Spacing.s)
                    Text(timeRange)
                        .font(TypeScale.numeric)
                        .foregroundStyle(.secondary)
                }

                Text(subtitle)
                    .font(TypeScale.rowBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(background)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle), \(timeRange)")
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.selection) }
        if isHovering { return Surface.hover }
        return AnyShapeStyle(.clear)
    }
}

/// The leading icon rail shared by every timeline row, so titles line up down
/// the whole list whatever kind of thing the row stands for.
struct RowIcon: View {
    let systemImage: String
    var isActive = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 20, height: 20)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(.tint.opacity(0.14)) : Surface.card)
            }
            .accessibilityHidden(true)
    }
}

/// "Live" as a dot and a word, never colour alone.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(.green)
                .frame(width: 5, height: 5)
            Text("Live")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.green)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.green.opacity(0.12), in: Capsule())
        .accessibilityLabel("In progress")
    }
}

/// Renders the FTS snippet, emphasising the matched terms the store wraps in
/// `‹ ›` rather than showing the markers themselves.
struct HighlightedSnippet: View {
    let snippet: String

    var body: some View {
        Text(attributed)
            .font(TypeScale.rowBody)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        var buffer = ""
        var emphasised = false

        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            if emphasised {
                run.font = TypeScale.rowBody.weight(.semibold)
                run.foregroundColor = .primary
            }
            result.append(run)
            buffer = ""
        }

        for character in snippet {
            switch character {
            case "‹":
                flush()
                emphasised = true
            case "›":
                flush()
                emphasised = false
            default:
                buffer.append(character)
            }
        }
        flush()
        return result
    }
}
