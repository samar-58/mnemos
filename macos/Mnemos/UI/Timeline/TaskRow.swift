import SwiftUI

/// A memory as a card: what you did, told in three lines. Counts and confidence
/// live behind developer details.
struct TaskRow: View {
    let task: TaskMemory
    let result: ContextSearchResult?

    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s - 2) {
                if task.isPinned {
                    Image(systemName: Glyph.pinned)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
                Text(Narrative.title(for: task))
                    .font(.headline)
                    .lineLimit(1)
                if task.isOpen {
                    Chip(text: "Live", tint: .green)
                }
                Spacer(minLength: Spacing.s)
                Text(task.endedAt, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let highlight = result?.highlights.first {
                HighlightedSnippet(snippet: highlight)
            } else {
                Text(Narrative.summary(for: task))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: Spacing.m) {
                Text(Narrative.meta(for: task))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if showsDeveloperDetails {
                    MetaLabel(text: "\(task.eventCount)", symbol: Glyph.evidence)
                }
                Spacer(minLength: 0)
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

/// Renders the FTS snippet, emphasising the matched terms the store wraps in
/// `‹ ›` rather than showing the markers themselves.
struct HighlightedSnippet: View {
    let snippet: String

    var body: some View {
        Text(attributed)
            .font(.caption)
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
                run.font = .caption.weight(.semibold)
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
