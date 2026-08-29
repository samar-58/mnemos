import Foundation

/// One line in the task list.
///
/// The engine starts a new task whenever a work session breaks — a 15 minute
/// idle gap is enough — so a single afternoon on one repository is stored as
/// half a dozen episodes with identical titles. That is correct as memory and
/// useless as a list: it reads as six empty copies of the same thing.
///
/// The timeline therefore shows one entry per project per day. An entry that
/// covers several episodes reports the span and the count, and expands to the
/// episodes underneath. Nothing is merged in the store; this is purely how the
/// day is presented.
struct TimelineGroup: Identifiable, Equatable {
    /// Tasks newest first, exactly as they came out of the store.
    let tasks: [TaskMemory]
    /// The workstream id when these were grouped by project, nil when they were
    /// grouped by a shared title.
    let workstreamID: String?

    var id: String { tasks.first?.id ?? UUID().uuidString }

    /// The task that supplies the entry's title, project, and open state.
    var lead: TaskMemory { tasks[0] }

    /// True when this entry stands for more than one episode and should render
    /// as an expandable group.
    var isGroup: Bool { tasks.count > 1 }

    var taskIDs: Set<String> { Set(tasks.map(\.id)) }

    var isOpen: Bool { tasks.contains(where: \.isOpen) }

    var isPinned: Bool { tasks.contains(where: \.isPinned) }

    var startedAt: Date { tasks.map(\.startedAt).min() ?? lead.startedAt }

    var endedAt: Date { tasks.map(\.endedAt).max() ?? lead.endedAt }

    /// Time actually spent, summed across the episodes rather than measured
    /// from first to last — the gaps between episodes are precisely the time
    /// the user was doing something else.
    var activeSeconds: TimeInterval {
        tasks.reduce(0) { $0 + max(0, $1.endedAt.timeIntervalSince($1.startedAt)) }
    }

    var eventCount: Int { tasks.reduce(0) { $0 + $1.eventCount } }

    /// Every application touched across the entry, most-used first.
    var applications: [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for task in tasks {
            for application in task.applications {
                if counts[application] == nil { order.append(application) }
                counts[application, default: 0] += 1
            }
        }
        return order.sorted { (counts[$0] ?? 0, $1) > (counts[$1] ?? 0, $0) }
    }

    // MARK: - Grouping

    /// Groups one day's tasks into entries: by project where there is one, by
    /// normalised title where there is not. Entries are ordered by their most
    /// recent episode, and the episodes inside keep the store's order.
    static func group(_ tasks: [TaskMemory]) -> [TimelineGroup] {
        var order: [String] = []
        var buckets: [String: [TaskMemory]] = [:]
        var workstreamIDs: [String: String] = [:]

        for task in tasks {
            let key: String
            if task.isUserLocked {
                key = "task:\(task.id)"
            } else if let workstream = task.workstream {
                key = "workstream:\(workstream.id)"
                workstreamIDs[key] = workstream.id
            } else {
                key = "title:\(normalized(Narrative.title(for: task)))"
            }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(task)
        }

        return order.compactMap { key in
            guard let grouped = buckets[key], !grouped.isEmpty else { return nil }
            return TimelineGroup(tasks: grouped, workstreamID: workstreamIDs[key])
        }
    }

    /// A title a person renamed is theirs alone and never folds into a group,
    /// so the key keeps the exact text; everything else folds on case and
    /// whitespace.
    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
