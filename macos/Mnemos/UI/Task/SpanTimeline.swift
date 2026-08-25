import SwiftUI

/// One stretch of work in a single app, rendered as a row on a time rail.
struct SpanRow: View {
    let span: ActivitySpan

    private var context: String? {
        span.windowTitle ?? span.anchorKey
    }

    private var artifact: String? {
        span.url ?? span.documentPath
    }

    private var glyph: String {
        if span.url != nil { return Glyph.browser }
        if span.documentPath != nil { return Glyph.document }
        return Glyph.application
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Text(span.startedAt, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Capsule()
                .fill(.tint.opacity(0.35))
                .frame(width: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs - 1) {
                HStack(spacing: Spacing.s - 2) {
                    Image(systemName: glyph)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(span.applicationName)
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: Spacing.s)
                    Text(Elapsed.label(from: span.startedAt, to: span.endedAt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if let context, !context.isEmpty {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let artifact {
                    CodeText(text: artifact, lineLimit: 1)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(span.applicationName), \(span.startedAt.formatted(date: .omitted, time: .shortened)), \(context ?? "no window title")"
        )
    }
}
