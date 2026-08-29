import SwiftUI

/// A status indicator that always pairs colour with a text label supplied by
/// the caller, so state is never communicated by colour alone.
struct StatusDot: View {
    let tint: Color
    var isPulsing = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .opacity(isPulsing ? 1 : 0.9)
            .accessibilityHidden(true)
    }
}

/// A small capsule used for counts, kinds, and inline state such as "Live".
struct Chip: View {
    let text: String
    var tint: Color?
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, Spacing.s - 2)
        .padding(.vertical, 2)
        .background(
            (tint ?? Color.secondary).opacity(0.12),
            in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
        )
    }
}

/// A list section heading: a quiet uppercase label, with an optional figure on
/// the right such as the time recorded that day.
struct SectionHeading: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(title.uppercased())
                .font(TypeScale.section)
                .foregroundStyle(.secondary)
                .kerning(0.4)
            Spacer(minLength: Spacing.s)
            if let trailing {
                Text(trailing)
                    .font(TypeScale.numeric)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// A non-blocking failure notice pinned above a scrolling list.
struct InlineBanner: View {
    let message: String
    var symbol = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(TypeScale.meta)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A titled block of content in the detail pane. Replaces the bare heading and
/// paragraph pairs, so every section of a memory has the same shape.
struct DetailCard<Content: View>: View {
    let title: String
    var symbol: String?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title.uppercased())
                    .font(TypeScale.section)
                    .foregroundStyle(.secondary)
                    .kerning(0.4)
                Spacer(minLength: Spacing.s)
                if let trailing {
                    Text(trailing)
                        .font(TypeScale.numeric)
                        .foregroundStyle(.tertiary)
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// Caption-weight metadata with a leading symbol, used in list rows.
struct MetaLabel: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}

/// A definition-list row: a fixed-width label beside selectable content.
struct DetailRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            content
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

extension DetailRow where Content == Text {
    init(_ label: String, value: String) {
        self.init(label: label) { Text(value) }
    }
}

/// Grouping confidence as a plain-language label; the underlying reasons stay
/// available as a tooltip rather than as visible jargon.
struct ConfidenceIndicator: View {
    let confidence: Double
    let reasons: [String]

    private var descriptor: String {
        switch confidence {
        case 0.75...: "Grouped with high confidence"
        case 0.45..<0.75: "Grouped with medium confidence"
        default: "Grouped with low confidence"
        }
    }

    private var tint: Color {
        switch confidence {
        case 0.75...: .green
        case 0.45..<0.75: .secondary
        default: .orange
        }
    }

    var body: some View {
        HStack(spacing: Spacing.s - 2) {
            StatusDot(tint: tint)
            Text(descriptor)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(reasons.isEmpty ? descriptor : "\(descriptor) — \(reasons.joined(separator: ", "))")
        .accessibilityLabel(reasons.isEmpty ? descriptor : "\(descriptor), because \(reasons.joined(separator: ", "))")
    }
}

/// Monospaced, selectable text for paths, URLs, and tokens.
struct CodeText: View {
    let text: String
    var lineLimit: Int? = 2

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
    }
}
