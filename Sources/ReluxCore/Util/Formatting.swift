import Foundation

public enum Formatting {
    /// Binary units with no sub-kilobyte branch: 0 and 1 byte both render as "0 KB".
    public static func bytes(_ bytes: Int) -> String {
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 {
            return String(format: "%.0f KB", kilobytes)
        }
        return String(format: "%.1f MB", kilobytes / 1024)
    }

    public static func time(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return makeTodayFormatter().string(from: date)
        }
        return makeDateFormatter().string(from: date)
    }

    /// DateFormatter is not Sendable, so a cached instance cannot be shared from a
    /// non-isolated enum under Swift 6; the format styles are cheap to rebuild.
    private static func makeTodayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "'Today at' HH:mm:ss"
        return formatter
    }

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}
