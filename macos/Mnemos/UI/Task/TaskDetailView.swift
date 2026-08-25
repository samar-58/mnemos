import SwiftUI

struct TaskDetailView: View {
    let task: TaskMemory
    @EnvironmentObject private var browser: MemoryBrowser
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        List(selection: $browser.selectedSpanIDs) {
            Section {
                header
                    .listRowSeparator(.hidden)
                summary
            }
            .selectionDisabled()

            Section {
                if browser.selectedTaskSpans.isEmpty {
                    Text("No activity recorded for this task.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(browser.selectedTaskSpans) { span in
                        SpanRow(span: span)
                            .tag(span.id)
                            .contextMenu { spanMenu(for: span) }
                    }
                }
            } header: {
                HStack {
                    Text("Activity")
                    Spacer()
                    if !browser.selectedTaskSpans.isEmpty {
                        Text("Select to split or move")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(task.title)
        .navigationSubtitle(timeRange)
        .onAppear { titleDraft = task.title }
        .onChange(of: task.id) { _, _ in titleDraft = task.title }
        .onChange(of: task.title) { _, newValue in
            if !titleFocused { titleDraft = newValue }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
        .onChange(of: browser.renameRequestID) { _, requested in
            if requested == task.id {
                titleFocused = true
                browser.renameRequestID = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                TextField("Task title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit {
                        commitTitle()
                        titleFocused = false
                    }
                    .accessibilityLabel("Task title")

                if task.isOpen { Chip(text: "Live", tint: .green) }

                Button {
                    browser.togglePin(taskID: task.id)
                } label: {
                    Image(systemName: task.isPinned ? Glyph.pinned : Glyph.unpinned)
                        .foregroundStyle(task.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .help(task.isPinned ? "Unpin this task" : "Pin this task")
                .accessibilityLabel(task.isPinned ? "Unpin" : "Pin")
            }

            if !task.digest.isEmpty {
                Text(task.digest)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            ConfidenceIndicator(confidence: task.groupingConfidence, reasons: task.groupingReasons)
        }
        .padding(.vertical, Spacing.s)
    }

    @ViewBuilder
    private var summary: some View {
        DetailRow("When", value: timeRange)

        DetailRow(label: "Workstream") {
            Menu {
                Button("None") { browser.assignSelectedTask(toWorkstream: nil) }
                Divider()
                ForEach(browser.workstreams) { summary in
                    Button(summary.workstream.displayName) {
                        browser.assignSelectedTask(toWorkstream: summary.workstream.id)
                    }
                }
            } label: {
                Text(task.workstream?.displayName ?? "None")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }

        if let state = task.lastState, !state.isEmpty {
            DetailRow(label: "Left off at") {
                Text(state).textSelection(.enabled)
            }
        }

        if !task.applications.isEmpty {
            DetailRow("Apps", value: task.applications.joined(separator: ", "))
        }

        if !task.actions.isEmpty {
            DetailRow("Actions", value: task.actions.joined(separator: ", "))
        }

        if !task.artifacts.isEmpty {
            DetailRow(label: "Files and links") {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(task.artifacts, id: \.self) { artifact in
                        CodeText(text: artifact, lineLimit: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func spanMenu(for span: ActivitySpan) -> some View {
        Button("Split into a New Task") {
            ensureSelected(span)
            browser.splitSelectedSpans()
        }
        Menu("Move to") {
            ForEach(browser.displayedTasks.filter { $0.id != task.id }) { other in
                Button(other.title) {
                    ensureSelected(span)
                    browser.moveSelectedSpans(to: other.id)
                }
            }
        }
        .disabled(browser.displayedTasks.count < 2)
    }

    /// Right-clicking a span that is not part of the current selection acts on
    /// that span alone, matching Finder.
    private func ensureSelected(_ span: ActivitySpan) {
        if !browser.selectedSpanIDs.contains(span.id) {
            browser.selectedSpanIDs = [span.id]
        }
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            titleDraft = task.title
            return
        }
        guard trimmed != task.title else { return }
        browser.rename(trimmed, taskID: task.id)
    }

    private var timeRange: String {
        let start = task.startedAt.formatted(date: .abbreviated, time: .shortened)
        let end = task.endedAt.formatted(date: .omitted, time: .shortened)
        let duration = Elapsed.label(from: task.startedAt, to: task.endedAt)
        return task.isOpen ? "\(start) · running for \(Elapsed.label(from: task.startedAt))" : "\(start) – \(end) · \(duration)"
    }
}

/// Shown when nothing is selected, or when several tasks are.
struct TaskDetailPlaceholder: View {
    let selectedCount: Int

    var body: some View {
        if selectedCount > 1 {
            ContentUnavailableView {
                Label("\(selectedCount) tasks selected", systemImage: Glyph.task)
            } description: {
                Text("Merge them from the Memory menu, or select a single task to inspect it.")
            }
        } else {
            ContentUnavailableView {
                Label("No task selected", systemImage: Glyph.task)
            } description: {
                Text("Choose a task to see what you were doing and the evidence behind it.")
            }
        }
    }
}
