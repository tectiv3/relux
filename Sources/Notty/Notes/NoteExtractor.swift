import AppKit
import Foundation

final class NoteExtractor {
    enum ExtractionError: Error, LocalizedError {
        case scriptFailed(String)
        case notesAppUnavailable

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message):
                return "AppleScript execution failed: \(message)"
            case .notesAppUnavailable:
                return "Notes.app is not available"
            }
        }
    }

    private static let noteDelimiter = "<<<NOTE>>>"
    private static let fieldSeparator = "<<<SEP>>>"

    func fetchAllNotes() throws -> [NoteRecord] {
        ensureNotesRunning()

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
                            set noteFolder to name of container of eachNote
                        end try
                        set modDate to modification date of eachNote
                        set output to output & "<<<NOTE>>>" & noteId & "<<<SEP>>>" & noteTitle & "<<<SEP>>>" & noteBody & "<<<SEP>>>" & noteFolder & "<<<SEP>>>" & (modDate as string)
                    end try
                end repeat
            end tell
            return output
            """

        guard let appleScript = NSAppleScript(source: script) else {
            throw ExtractionError.scriptFailed("Failed to create NSAppleScript instance")
        }

        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)

        if let errorDict = errorDict {
            let message =
                errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            throw ExtractionError.scriptFailed(message)
        }

        guard let output = result.stringValue else {
            return []
        }

        return parseNotes(from: output)
    }

    // MARK: - Private

    private func ensureNotesRunning() {
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Notes"
        }

        if !isRunning {
            guard let notesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else {
                return
            }
            NSWorkspace.shared.open(notesURL)
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func parseNotes(from output: String) -> [NoteRecord] {
        let rawNotes = output.components(separatedBy: Self.noteDelimiter)

        return rawNotes.compactMap { chunk -> NoteRecord? in
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let fields = trimmed.components(separatedBy: Self.fieldSeparator)
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

    private func htmlToPlainText(_ html: String) -> String {
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

    private func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // AppleScript date format varies by locale; try common patterns
        let formats = [
            "EEEE, MMMM d, yyyy 'at' h:mm:ss a",
            "yyyy-MM-dd HH:mm:ss Z",
            "MM/dd/yyyy HH:mm:ss",
            "dd/MM/yyyy HH:mm:ss",
            "EEEE d MMMM yyyy HH:mm:ss",
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        // Fallback: let the system try natural language parsing
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = detector?.firstMatch(in: trimmed, range: range) {
            return match.date
        }

        return nil
    }
}
