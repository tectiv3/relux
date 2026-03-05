import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.notty.app", category: "clipboardmonitor")

@MainActor
@Observable
final class ClipboardMonitor {
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    var suppressNextCapture = false

    /// Bundle IDs of apps whose copies should be ignored
    var disabledApps: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: "clipboardDisabledApps") ?? [
                "com.apple.keychainaccess",
                "com.apple.Passwords",
            ]
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "clipboardDisabledApps")
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "clipboardEnabled")
            if newValue { start() } else { stop() }
        }
    }

    init(store: ClipboardStore) {
        self.store = store
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard isEnabled, timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkClipboard()
            }
        }
        log.info("Clipboard monitoring started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        log.info("Clipboard monitoring stopped")
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if suppressNextCapture {
            suppressNextCapture = false
            return
        }

        // Check if frontmost app is disabled
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontApp.bundleIdentifier,
           disabledApps.contains(bundleId)
        {
            log.info("Skipping clipboard from disabled app: \(bundleId)")
            return
        }

        captureClipboard(pb)
    }

    private func captureClipboard(_ pb: NSPasteboard) {
        let sourceApp = NSWorkspace.shared.frontmostApplication
        let sourceBundle = sourceApp?.bundleIdentifier
        let sourceName = sourceApp?.localizedName

        // Priority: image → RTF → HTML → plain text
        if let imageData = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
            captureImage(imageData, sourceApp: sourceBundle, sourceName: sourceName)
        } else if let rtfData = pb.data(forType: .rtf), let plainText = pb.string(forType: .string) {
            captureRichText(contentType: "rtf", rawData: rtfData, plainText: plainText, sourceApp: sourceBundle, sourceName: sourceName)
        } else if let htmlData = pb.data(forType: .html), let plainText = pb.string(forType: .string) {
            captureRichText(contentType: "html", rawData: htmlData, plainText: plainText, sourceApp: sourceBundle, sourceName: sourceName)
        } else if let text = pb.string(forType: .string) {
            capturePlainText(text, sourceApp: sourceBundle, sourceName: sourceName)
        }
    }

    private func capturePlainText(_ text: String, sourceApp: String?, sourceName: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !store.isDuplicate(textContent: text) else { return }

        do {
            try store.insert(
                contentType: "text",
                textContent: text,
                rawData: nil,
                imagePath: nil,
                imageWidth: nil,
                imageHeight: nil,
                imageSize: nil,
                sourceApp: sourceApp,
                sourceName: sourceName
            )
        } catch {
            log.error("Failed to store clipboard text: \(error.localizedDescription)")
        }
    }

    private func captureRichText(contentType: String, rawData: Data, plainText: String, sourceApp: String?, sourceName: String?) {
        guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !store.isDuplicate(textContent: plainText) else { return }

        do {
            try store.insert(
                contentType: contentType,
                textContent: plainText,
                rawData: rawData,
                imagePath: nil,
                imageWidth: nil,
                imageHeight: nil,
                imageSize: nil,
                sourceApp: sourceApp,
                sourceName: sourceName
            )
        } catch {
            log.error("Failed to store clipboard rich text: \(error.localizedDescription)")
        }
    }

    private func captureImage(_ data: Data, sourceApp: String?, sourceName: String?) {
        guard let image = NSImage(data: data) else { return }
        let width = Int(image.size.width)
        let height = Int(image.size.height)

        // Save as PNG
        guard let tiffRep = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffRep),
              let pngData = bitmapRep.representation(using: .png, properties: [:])
        else { return }

        let filename = "\(UUID().uuidString).png"
        let filePath = store.imageDir.appendingPathComponent(filename)

        do {
            try pngData.write(to: filePath)
            try store.insert(
                contentType: "image",
                textContent: nil,
                rawData: nil,
                imagePath: filename,
                imageWidth: width,
                imageHeight: height,
                imageSize: pngData.count,
                sourceApp: sourceApp,
                sourceName: sourceName
            )
        } catch {
            log.error("Failed to store clipboard image: \(error.localizedDescription)")
        }
    }
}
