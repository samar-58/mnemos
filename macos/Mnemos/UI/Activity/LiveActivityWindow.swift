import SwiftUI

/// The raw event stream, kept out of the main window. Useful for checking what
/// Mnemos can actually see from an app.
struct LiveActivityWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: CapturedEvent.ID?

    private var selectedEvent: CapturedEvent? {
        guard let selection else { return nil }
        return model.events.first { $0.id == selection }
    }

    var body: some View {
        VSplitView {
            table
                .frame(minHeight: 220)
            detail
                .frame(minHeight: 120)
        }
        .navigationTitle("Live Activity")
        .navigationSubtitle(model.events.isEmpty ? "No events" : "\(model.events.count) recent events")
        .toolbar {
            ToolbarItemGroup {
                Button(model.isRunning ? "Pause" : "Start") { model.toggleCapture() }
                Button("Clear") { model.clearEvents() }
                    .disabled(model.events.isEmpty)
            }
        }
    }

    private var table: some View {
        Table(model.events, selection: $selection) {
            TableColumn("Time") { event in
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(74)

            TableColumn("App") { event in
                Text(event.applicationName).lineLimit(1)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Kind") { event in
                Text(EventKindLabel.label(for: event.kind.rawValue))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Context") { event in
                Text(summary(for: event)).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let event = selectedEvent {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    DetailRow("App", value: "\(event.applicationName) · \(event.bundleID)")
                    if let title = event.windowTitle {
                        DetailRow("Window", value: title)
                    }
                    if let path = event.documentPath {
                        DetailRow(label: "Document") { CodeText(text: path, lineLimit: 3) }
                    }
                    if let url = event.url {
                        DetailRow(label: "URL") { CodeText(text: url, lineLimit: 3) }
                    }
                    if let target = event.target?.summary {
                        DetailRow("Target", value: target)
                    }
                    if let detail = event.detail {
                        DetailRow(label: "Detail") {
                            Text(detail).textSelection(.enabled)
                        }
                    }
                    if let axText = event.axText {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Accessibility text")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(axText)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Spacing.s)
                                .background(
                                    .quaternary.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                )
                        }
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("No event selected", systemImage: Glyph.evidence)
            } description: {
                Text("Select an event to see everything Mnemos captured from it.")
            }
        }
    }

    private func summary(for event: CapturedEvent) -> String {
        event.detail
            ?? event.windowTitle
            ?? event.url
            ?? event.documentPath
            ?? event.target?.summary
            ?? "—"
    }
}
