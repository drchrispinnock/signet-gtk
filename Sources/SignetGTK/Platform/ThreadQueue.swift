import Foundation

/// A serial queue whose work all runs on one dedicated thread. JavaScriptCore's GLib API must be
/// used from the thread that made the context, which a `DispatchQueue` does not promise, so the
/// Linux `TaquitoBridge` runs on one of these instead. It offers the `DispatchQueue` calls the
/// Mac bridge makes (`async`, `asyncAfter` with a closure or a `DispatchWorkItem`), so the two
/// files read the same. The thread ends once the queue is gone and its work has run.
final class ThreadQueue: @unchecked Sendable {
    private struct Item {
        let due: DispatchTime
        let order: Int
        let work: @Sendable () -> Void
    }

    /// What the thread shares with the queue; the thread holds only this, never the queue.
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        /// Pending work, soonest first; ties run in the order they were added.
        var items: [Item] = []
        var nextOrder = 0
        var released = false
        weak var thread: Thread?
    }

    private let state = State()

    init(label: String) {
        let state = self.state
        let thread = Thread { Self.run(state) }
        thread.name = label
        thread.qualityOfService = .userInitiated
        state.thread = thread
        thread.start()
    }

    deinit {
        state.condition.withLock {
            state.released = true
            state.condition.signal()
        }
    }

    /// Whether the caller is running on this queue's thread.
    var isCurrent: Bool { state.condition.withLock { state.thread } == Thread.current }

    func async(execute work: @escaping @Sendable () -> Void) {
        schedule(at: .now(), work)
    }

    func asyncAfter(deadline: DispatchTime, execute work: @escaping @Sendable () -> Void) {
        schedule(at: deadline, work)
    }

    /// Runs `item` at `deadline` unless it has been cancelled by then.
    func asyncAfter(deadline: DispatchTime, execute item: DispatchWorkItem) {
        nonisolated(unsafe) let item = item
        schedule(at: deadline) { if !item.isCancelled { item.perform() } }
    }

    private func schedule(at due: DispatchTime, _ work: @escaping @Sendable () -> Void) {
        state.condition.withLock {
            let item = Item(due: due, order: state.nextOrder, work: work)
            state.nextOrder += 1
            let index = state.items.firstIndex { $0.due > due } ?? state.items.endIndex
            state.items.insert(item, at: index)
            state.condition.signal()
        }
    }

    /// Runs work as it falls due. Once the queue is released only work already due runs; timers
    /// still waiting are dropped, as nothing could observe them.
    private static func run(_ state: State) {
        while true {
            state.condition.lock()
            while true {
                if let first = state.items.first {
                    let now = DispatchTime.now()
                    if first.due <= now { break }
                    if state.released { state.items.removeAll(); continue }
                    let wait = Double(first.due.uptimeNanoseconds - now.uptimeNanoseconds) / 1e9
                    _ = state.condition.wait(until: Date(timeIntervalSinceNow: wait))
                } else if state.released {
                    state.condition.unlock()
                    return
                } else {
                    state.condition.wait()
                }
            }
            let item = state.items.removeFirst()
            state.condition.unlock()
            item.work()
        }
    }
}
