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
            let entries = (try? store.getEntries(at: position))?.compactMap { $0 as? OSLogEntryLog }
            if let entries, entries.contains(where: {
                $0.subsystem == subsystem && $0.category == category && $0.composedMessage.contains(text)
            }) {
                return true
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
