import SwiftUI

struct TaskDetailView: View {
    let task: TaskMemory
    @EnvironmentObject private var browser: MemoryBrowser
    @AppStorage(DeveloperDetails.defaultsKey) private var showsDeveloperDetails = false
    @AppStorage("showsEvidenceInspector") private var showsInspector = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        List(selection: $browser.selectedSpanIDs) {
            Section {
                header
                    .listRowSeparator(.hidden)
                story
                    .listRowSeparator(.hidden)
            }
            .selectionDisabled()

            Section("Related items") {
                related
            }
            .selectionDisabled()

            Section {
                if browser.selectedTaskSpans.isEmpty {
                    Text("Nothing recorded for this task yet.")
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
        .navigationTitle(Narrative.title(for: task))
        .navigationSubtitle(Narrative.timeRange(for: task))
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
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

            Text(Narrative.meta(for: task))
                .font(.caption)
                .foregroundStyle(.secondary)

            if showsDeveloperDetails {
                ConfidenceIndicator(confidence: task.groupingConfidence, reasons: task.groupingReasons)
            }
        }
        .padding(.vertical, Spacing.s)
    }

    /// The two questions a person actually opens a memory to answer.
    @ViewBuilder
    private var story: some View {
        StoryBlock(title: "What you were doing") {
            Text(showsDeveloperDetails ? task.digest : Narrative.summary(for: task))
                .textSelection(.enabled)
        }

        if let place = Narrative.lastPlace(for: task) {
            StoryBlock(title: "Where you left off") {
                Text(place)
                    .textSelection(.enabled)
                    .help(task.lastState ?? place)
            }
        }
    }

    @ViewBuilder
    private var related: some View {
        ForEach(task.artifacts, id: \.self) { artifact in
            let item = Narrative.artifact(artifact)
            Label(item.label, systemImage: Glyph.document)
                .lineLimit(1)
                .help(item.detail)
                .textSelection(.enabled)
                .accessibilityLabel(item.detail)
        }

        Menu {
            Button("None") { browser.assignSelectedTask(toWorkstream: nil) }
            Divider()
            ForEach(browser.workstreams) { summary in
                Button(summary.workstream.displayName) {
                    browser.assignSelectedTask(toWorkstream: summary.workstream.id)
                }
            }
        } label: {
            Label(task.workstream?.displayName ?? "No project", systemImage: Glyph.workstream)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Move this task to another project")
    }

    /// One clear action, and a quiet way to see the raw material behind it.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.s) {
                Button("Copy context") {
                    ContextClipboard.copy(task: task, evidence: browser.selectedTaskEvidence)
                }
                .buttonStyle(.borderedProminent)
                .help("Copy this memory as context for an agent")

                Spacer()

                Button(showsInspector ? "Hide what Mnemos saw" : "Show what Mnemos saw") {
                    showsInspector.toggle()
                }
                .buttonStyle(.link)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s + 1)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func spanMenu(for span: ActivitySpan) -> some View {
        Button("Split into a New Task") {
            ensureSelected(span)
            browser.splitSelectedSpans()
        }
        Menu("Move to") {
            ForEach(browser.displayedTasks.filter { $0.id != task.id }) { other in
                Button(Narrative.title(for: other)) {
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
}

/// A short heading over a paragraph, used for the conversational blocks.
private struct StoryBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.xs)
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
                Text("Merge them from the Memory menu, or select a single task to see it.")
            }
        } else {
            ContentUnavailableView {
                Label("No task selected", systemImage: Glyph.task)
            } description: {
                Text("Choose a task to see what you were doing and where you left off.")
            }
        }
    }
}
