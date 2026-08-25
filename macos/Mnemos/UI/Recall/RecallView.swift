import AppKit
import SwiftUI

/// The recall panel's contents: type, pick, open. Deliberately one field and
/// one list — filters live in the main window.
struct RecallView: View {
    let onOpen: (String) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var browser: MemoryBrowser
    @State private var query = ""
    @State private var results: [ContextSearchResult] = []
    @State private var highlighted = 0
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private var selected: ContextSearchResult? {
        results.indices.contains(highlighted) ? results[highlighted] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if !results.isEmpty {
                Divider()
                list
            } else if !query.isEmpty, !isSearching {
                Divider()
                Text("No matching memory")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.m)
            }
            if selected != nil {
                Divider()
                hints
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Radius.container + 2, style: .continuous))
        .frame(width: 620)
        .onExitCommand(perform: onDismiss)
        .onAppear {
            fieldFocused = true
            highlighted = 0
        }
        .background {
            Button("Copy", action: copySelected)
                .keyboardShortcut("c", modifiers: .command)
                .hidden()
        }
    }

    private var field: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: Glyph.search)
                .foregroundStyle(.secondary)
            TextField("Recall what you were working on", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) {
                    move(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onChange(of: query) { _, _ in scheduleSearch() }
            if isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        RecallResultRow(result: result, isHighlighted: index == highlighted)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                highlighted = index
                                openHighlighted()
                            }
                    }
                }
            }
            .frame(maxHeight: 320)
            .onChange(of: highlighted) { _, index in
                guard results.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(results[index].id, anchor: .center)
                }
            }
        }
    }

    private var hints: some View {
        HStack(spacing: Spacing.l) {
            Label("Open", systemImage: "return")
            Label("Copy context", systemImage: "command")
            Spacer()
            Text("esc to close")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await browser.quickSearch(text)
            guard !Task.isCancelled else { return }
            results = found
            highlighted = 0
            isSearching = false
        }
    }

    private func move(by offset: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(highlighted + offset, 0), results.count - 1)
    }

    private func openHighlighted() {
        guard let selected else { return }
        onOpen(selected.task.id)
    }

    /// Copies a compact, agent-ready summary of the highlighted task.
    private func copySelected() {
        guard let selected else { return }
        let task = selected.task
        var lines = ["# \(task.title)"]
        lines.append(task.startedAt.formatted(date: .abbreviated, time: .shortened))
        if !task.digest.isEmpty { lines.append(task.digest) }
        if let state = task.lastState, !state.isEmpty { lines.append("Left off at: \(state)") }
        if !task.artifacts.isEmpty {
            lines.append("Files and links:")
            lines.append(contentsOf: task.artifacts.prefix(6).map { "- \($0)" })
        }
        let excerpts = selected.evidencePreviews.compactMap(\.excerpt).prefix(4)
        if !excerpts.isEmpty {
            lines.append("Evidence:")
            lines.append(contentsOf: excerpts.map { "- \($0)" })
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct RecallResultRow: View {
    let result: ContextSearchResult
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: result.task.isOpen ? Glyph.live : Glyph.task)
                .foregroundStyle(result.task.isOpen ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.task.title)
                    .font(.headline)
                    .lineLimit(1)
                if let highlight = result.highlights.first {
                    HighlightedSnippet(snippet: highlight)
                } else if !result.task.digest.isEmpty {
                    Text(result.task.digest)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.s)
            Text(result.task.endedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s + 2)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(.tint.opacity(0.16))
                    .padding(.horizontal, Spacing.s)
            }
        }
    }
}
