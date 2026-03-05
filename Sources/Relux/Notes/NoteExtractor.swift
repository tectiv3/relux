import AppKit
import Foundation

final class NoteExtractor: Sendable {
    enum ExtractionError: Error, LocalizedError {
        case scriptFailed(String)
        case notesAppUnavailable

        var errorDescription: String? {
            switch self {
            case let .scriptFailed(message):
                "AppleScript execution failed: \(message)"
            case .notesAppUnavailable:
                "Notes.app is not available"
            }
        }
    }

    private static let noteDelimiter = "<<<NOTE>>>"
    private static let fieldSeparator = "<<<SEP>>>"

    func fetchAllNotes() async throws -> [NoteRecord] {
        await Self.ensureNotesRunning()

        let script = """
        set output to ""
        tell application "Notes"
            repeat with eachNote in every note
                try
                    set noteId to id of eachNote
                    set noteTitle to name of eachNote
                    set noteBody to body of eachNote
                    set noteFolder to "Unknown"
                    try
                        set c to container of eachNote
                        set noteFolder to name of c
                    end try
                    set modDate to modification date of eachNote
                    set output to output & "<<<NOTE>>>" & noteId & "<<<SEP>>>" & noteTitle & "<<<SEP>>>" & noteBody & "<<<SEP>>>" & noteFolder & "<<<SEP>>>" & (modDate as string)
                end try
            end repeat
        end tell
        return output
        """

        // AppleScript execution blocks the calling thread; run on a background thread
        let output: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(throwing: ExtractionError.scriptFailed("Failed to create NSAppleScript instance"))
                    return
                }

                var errorDict: NSDictionary?
                let result = appleScript.executeAndReturnError(&errorDict)

                if let errorDict {
                    let message =
                        errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: ExtractionError.scriptFailed(message))
                    return
                }

                continuation.resume(returning: result.stringValue ?? "")
            }
        }

        guard !output.isEmpty else { return [] }

        // Parse on background thread (HTML→plaintext is expensive for 152 notes)
        return await Task.detached {
            Self.parseNotes(from: output)
        }.value
    }

    // MARK: - Private

    @MainActor
    private static func ensureNotesRunning() {
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Notes"
        }

        if !isRunning {
            guard let notesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else {
                return
            }
            NSWorkspace.shared.open(notesURL)
        }
    }

    private static func parseNotes(from output: String) -> [NoteRecord] {
        let rawNotes = output.components(separatedBy: noteDelimiter)

        return rawNotes.compactMap { chunk -> NoteRecord? in
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let fields = trimmed.components(separatedBy: fieldSeparator)
            guard fields.count >= 5 else { return nil }

            let id = fields[0]
            let title = fields[1]
            let htmlBody = fields[2]
            let folder = fields[3]
            let dateString = fields[4]

            let plainText = htmlToPlainText(htmlBody)
            let modifiedDate = parseDate(dateString) ?? Date.distantPast

            return NoteRecord(
                id: id,
                title: title,
                plainText: plainText,
                folder: folder,
                modifiedDate: modifiedDate
            )
        }
    }

    private static func htmlToPlainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]

        guard
            let attributed = try? NSAttributedString(
                data: data,
                options: options,
                documentAttributes: nil
            )
        else {
            return html
        }

        return attributed.string
    }

    /// Open a note in Notes.app by its AppleScript ID
    static func openNote(id: String) {
        let escaped = id.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Notes"
            activate
            show note id "\(escaped)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEEE, MMMM d, yyyy 'at' h:mm:ss a",
            "yyyy-MM-dd HH:mm:ss Z",
            "MM/dd/yyyy HH:mm:ss",
            "dd/MM/yyyy HH:mm:ss",
            "EEEE d MMMM yyyy HH:mm:ss",
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let dateDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue
    )

    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        for formatter in dateFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = dateDetector?.firstMatch(in: trimmed, range: range) {
            return match.date
        }

        return nil
    }
}
