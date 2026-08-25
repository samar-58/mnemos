import SwiftUI

/// The app's permanent home. Enough to know what Mnemos is doing and to change
/// it without opening a window.
struct MenuBarPopover: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var browser: MemoryBrowser
    @Environment(\.openWindow) private var openWindow

    private var recentTasks: [TaskMemory] {
        Array(browser.recentTasks.filter { !$0.isOpen }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let open = model.openTask {
                section("In progress") {
                    PopoverRow {
                        TaskSummaryLabel(task: open, trailing: Elapsed.label(from: open.startedAt))
                    } action: {
                        reveal(open.id)
                    }
                }
                Divider()
            }

            if !recentTasks.isEmpty {
                section("Recent") {
                    ForEach(recentTasks) { task in
                        PopoverRow {
                            TaskSummaryLabel(task: task, trailing: task.endedAt.formatted(date: .omitted, time: .shortened))
                        } action: {
                            reveal(task.id)
                        }
                    }
                }
                Divider()
            }

            controls
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear {
            WindowActions.shared.register(openWindow)
            browser.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            StatusDot(tint: model.status.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.status.rawValue)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.m)
    }

    private var subtitle: String {
        guard model.accessibilityTrusted else { return "Accessibility access needed" }
        let count = model.tasksToday
        return count == 1 ? "1 task today" : "\(count) tasks today"
    }

    private var controls: some View {
        VStack(spacing: 0) {
            PopoverRow {
                Label(
                    model.isRunning ? "Pause Recording" : "Start Recording",
                    systemImage: model.isRunning ? Glyph.pause : Glyph.resume
                )
            } action: {
                model.toggleCapture()
            }

            PopoverRow {
                Label("Recall…", systemImage: Glyph.search)
            } action: {
                RecallPanelController.shared.show()
            }

            PopoverRow {
                HStack {
                    Label("Agent access", systemImage: Glyph.agents)
                    Spacer()
                    Text(model.agentAccessEnabled ? model.agentAPIStatus.label : "Off")
                        .font(.caption)
                        .foregroundStyle(model.agentAccessEnabled ? model.agentAPIStatus.tint : .secondary)
                }
            } action: {
                model.presentSettings(.agents)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            PopoverRow {
                Label("Open Mnemos", systemImage: "macwindow")
            } action: {
                WindowActions.shared.openMain()
            }

            SettingsLink {
                HStack {
                    Label("Settings…", systemImage: Glyph.general)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowStyle())

            PopoverRow {
                Label("Quit Mnemos", systemImage: "power")
            } action: {
                model.quit()
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.s)
                .padding(.bottom, Spacing.xs)
            content()
        }
        .padding(.bottom, Spacing.xs)
    }

    private func reveal(_ taskID: String) {
        WindowActions.shared.openMain()
        browser.reveal(taskID: taskID)
    }
}

private struct TaskSummaryLabel: View {
    let task: TaskMemory
    let trailing: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .lineLimit(1)
                if !task.digest.isEmpty {
                    Text(task.digest)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.s)
            Text(trailing)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

/// A full-width row that highlights on hover, matching the system menu feel.
struct PopoverRow<Content: View>: View {
    @ViewBuilder var content: Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowStyle())
    }
}

struct PopoverRowStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.body)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s - 1)
            .background {
                if isHovering || configuration.isPressed {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(.tint.opacity(configuration.isPressed ? 0.28 : 0.16))
                        .padding(.horizontal, Spacing.s - 2)
                }
            }
            .onHover { isHovering = $0 }
    }
}
