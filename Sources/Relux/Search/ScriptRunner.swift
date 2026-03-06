import AppKit
import SwiftUI

/// Runs scripts in the background and shows a floating toast with output.
@MainActor
enum ScriptRunner {
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
                    Toast.show(output, icon: "terminal")
                }
            }
        }
    }

    /// Runs a command, collects stdout, and replaces the selection in the previous app via AX API.
    static func runAndReplace(
        _ command: String, env: [String: String], stdin: String? = nil, in app: NSRunningApplication
    ) {
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.environment = env
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            if let stdin {
                let inputPipe = Pipe()
                process.standardInput = inputPipe
                inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
                inputPipe.fileHandleForWriting.closeFile()
            }

            try? process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
                await MainActor.run {
                    let msg = errMsg.isEmpty
                        ? "Script failed (exit \(process.terminationStatus))" : errMsg
                    Toast.show(msg, icon: "terminal")
                }
                return
            }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !output.isEmpty else { return }

            await MainActor.run {
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    let success = SelectionCapture.replaceSelectedText(with: output, in: app)
                    if !success {
                        Toast.show("Failed to replace selection", icon: "terminal")
                    }
                }
            }
        }
    }

    /// Runs a command and streams stdout chunks as they arrive.
    static func stream(_ command: String, env: [String: String], stdin: String? = nil) -> AsyncStream<String> {
        AsyncStream { continuation in
            let process = Process()

            Task.detached {
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
                    // Drain any remaining buffered data before finishing
                    let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
                        continuation.yield(text)
                    }
                    continuation.finish()
                }

                do {
                    try process.run()
                } catch {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}
