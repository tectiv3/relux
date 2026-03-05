import AppKit
import SwiftUI

/// Runs scripts in the background and shows a floating toast with output.
@MainActor
enum ScriptRunner {
    private static var toastWindow: NSWindow?
    private static var dismissTask: Task<Void, Never>?

    static func run(_ command: String, env: [String: String], stdin: String? = nil) {
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            if let stdin {
                let inputPipe = Pipe()
                process.standardInput = inputPipe
                inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
                inputPipe.fileHandleForWriting.closeFile()
            }

            try? process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            await MainActor.run {
                if !output.isEmpty {
                    showToast(output)
                }
            }
        }
    }

    /// Runs a command and streams stdout chunks as they arrive.
    static func stream(_ command: String, env: [String: String], stdin: String? = nil) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", command]
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                if let stdin {
                    let inputPipe = Pipe()
                    process.standardInput = inputPipe
                    inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    inputPipe.fileHandleForWriting.closeFile()
                }

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        return
                    }
                    if let text = String(data: data, encoding: .utf8) {
                        continuation.yield(text)
                    }
                }

                process.terminationHandler = { _ in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish()
                }

                do {
                    try process.run()
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    private static func showToast(_ message: String) {
        dismissTask?.cancel()
        toastWindow?.close()

        guard let screen = NSScreen.main else { return }

        let toast = NSHostingView(rootView:
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThickMaterial)
            .clipShape(Capsule()))
        toast.setFrameSize(toast.fittingSize)

        let maxWidth = min(toast.fittingSize.width, 600)
        let size = NSSize(width: maxWidth, height: toast.fittingSize.height)

        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.minY + 40
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.hasShadow = true
        window.contentView = toast
        window.alphaValue = 0

        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1
        }

        toastWindow = window

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                window.animator().alphaValue = 0
            } completionHandler: {
                window.close()
            }
        }
    }
}
