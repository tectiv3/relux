import Foundation
import OSLog

/// Reads back the unified log of this test process. A failure that is only logged is otherwise
/// invisible to a test, and the log is the channel the stores expose for it.
struct LogCapture {
    private let store: OSLogStore
    private let position: OSLogPosition

    init() throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        self.store = store
        position = store.position(date: Date())
    }

    /// Polls, because a freshly written entry is not guaranteed to be visible on the first read.
    func waitForError(
        subsystem: String = "com.relux.app",
        category: String,
        containing text: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if countErrors(subsystem: subsystem, category: category, containing: text) > 0 {
                return true
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Call after `waitForError`: the caller has already established that the entry is visible.
    func messages(
        subsystem: String = "com.relux.app",
        category: String,
        containing text: String
    ) -> [String] {
        let entries = (try? store.getEntries(at: position))?.compactMap { $0 as? OSLogEntryLog }
        return entries?.filter { entry in
            entry.subsystem == subsystem && entry.category == category
                && entry.composedMessage.contains(text)
        }.map(\.composedMessage) ?? []
    }

    func countErrors(
        subsystem: String = "com.relux.app",
        category: String,
        containing text: String
    ) -> Int {
        messages(subsystem: subsystem, category: category, containing: text).count
    }
}
