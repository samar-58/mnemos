import SwiftUI

struct TaskRow: View {
    let task: TaskMemory
    let result: ContextSearchResult?

    private var applicationSummary: String? {
        guard !task.applications.isEmpty else { return nil }
        let names = task.applications.prefix(2).joined(separator: ", ")
        let remainder = task.applications.count - 2
        return remainder > 0 ? "\(names) +\(remainder)" : names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s - 2) {
                if task.isPinned {
                    Image(systemName: Glyph.pinned)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
                Text(task.title)
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

            if !task.digest.isEmpty {
                Text(task.digest)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let highlight = result?.highlights.first {
                HighlightedSnippet(snippet: highlight)
            }

            HStack(spacing: Spacing.m) {
                if let applicationSummary {
                    MetaLabel(text: applicationSummary, symbol: Glyph.application)
                }
                MetaLabel(text: "\(task.eventCount)", symbol: Glyph.evidence)
                if let workstream = task.workstream {
                    MetaLabel(text: workstream.displayName, symbol: Glyph.workstream)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [task.title]
        if task.isPinned { parts.append("pinned") }
        if task.isOpen { parts.append("in progress") }
        parts.append(task.digest)
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
