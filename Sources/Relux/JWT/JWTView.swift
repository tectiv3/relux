import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.relux.app", category: "jwt")

struct JWTView: View {
    @Environment(AppState.self) private var appState
    @State private var inputText: String = ""
    @State private var showActions: Bool = false
    @State private var actionIndex: Int = 0
    @State private var keyMonitor: Any?
    @FocusState private var isInputFocused: Bool

    private var tokenParts: [String] {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ".")
    }

    private var headerPart: String {
        tokenParts.indices.contains(0) ? tokenParts[0] : ""
    }

    private var payloadPart: String {
        tokenParts.indices.contains(1) ? tokenParts[1] : ""
    }

    private var signaturePart: String {
        tokenParts.indices.contains(2) ? tokenParts[2] : ""
    }

    private var decodedHeader: String {
        decodeBase64(headerPart)
    }

    private var decodedPayload: String {
        decodeBase64(payloadPart)
    }

    private var isValidJWT: Bool {
        tokenParts.count >= 2 && !headerPart.isEmpty && !payloadPart.isEmpty
    }

    private var currentActions: [JWTAction] {
        guard isValidJWT else { return [] }
        return [
            JWTAction(label: "Copy Payload", icon: "doc.on.clipboard", shortcut: "\u{23CE}") {
                copyPayload()
            },
            JWTAction(label: "Copy Token", icon: "key", shortcut: nil) {
                copyToken()
            },
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 6)
            topBar
            Divider()

            if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState
            } else if !isValidJWT {
                errorState
            } else {
                HSplitView {
                    rawTokenView
                        .frame(minWidth: 200)
                    decodedView
                        .frame(minWidth: 200)
                }
            }

            Spacer(minLength: 0)
            Divider()
            bottomBar
        }
        .frame(width: 750)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            if showActions {
                actionsOverlay
            }
        }
        .onAppear {
            if let selection = appState.currentSelection, !selection.isEmpty {
                log.info("JWT view opened with selection (\(selection.prefix(40))...)")
                inputText = selection
                appState.currentSelection = nil
                saveToFrecency()
            } else {
                log.info("JWT view opened with no selection")
            }
            isInputFocused = true
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                appState.panelMode = .search
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)

            TextField("Paste JWT token...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .focused($isInputFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Content Views

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Paste a JWT token to decode")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text("Invalid JWT Format")
                .font(.headline)
            Text("Token must contain at least 2 base64-encoded parts separated by dots.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rawTokenView: some View {
        ScrollView {
            Text(rawTokenText)
                .font(.system(size: 14, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
        }
    }

    private var rawTokenText: AttributedString {
        var str = AttributedString("")

        if !headerPart.isEmpty {
            var header = AttributedString(headerPart)
            header.foregroundColor = .red
            str.append(header)
        }

        if !payloadPart.isEmpty {
            var dot = AttributedString(".")
            dot.foregroundColor = .secondary
            str.append(dot)

            var payload = AttributedString(payloadPart)
            payload.foregroundColor = .purple
            str.append(payload)
        }

        if !signaturePart.isEmpty {
            var dot = AttributedString(".")
            dot.foregroundColor = .secondary
            str.append(dot)

            var sig = AttributedString(signaturePart)
            sig.foregroundColor = .blue
            str.append(sig)
        }

        return str
    }

    private var decodedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HEADER: ALGORITHM & TOKEN TYPE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    if !decodedHeader.isEmpty {
                        Text(decodedHeader)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    } else {
                        Text("Could not decode header")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("PAYLOAD: DATA")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    if !decodedPayload.isEmpty {
                        TimestampAnnotatedText(text: decodedPayload, color: .purple)
                    } else {
                        Text("Could not decode payload")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Bottom Bar
}

// MARK: - Actions, Overlay & Key Monitor

extension JWTView {
    var bottomBar: some View {
        HStack(spacing: 16) {
            if showActions {
                keyboardHint(key: "\u{23CE}", label: "Select")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Back")
            } else {
                keyboardHint(key: "\u{23CE}", label: "Copy Payload")
                keyboardHint(key: "\u{2318}K", label: "Actions")
                keyboardHint(key: "esc", label: "Back")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    var actionsOverlay: some View {
        VStack(spacing: 0) {
            ForEach(Array(currentActions.enumerated()), id: \.offset) { index, action in
                actionRow(action: action, isSelected: index == actionIndex)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        action.action()
                        showActions = false
                    }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 220)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }

    func actionRow(action: JWTAction, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .font(.system(size: 13))
                .frame(width: 20)
            Text(action.label)
                .font(.system(size: 13))
            Spacer()
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(isSelected ? .white : .primary)
    }

    func keyboardHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                )
            Text(label)
        }
    }

    func copyPayload() {
        guard !decodedPayload.isEmpty else {
            log.debug("copyPayload: decodedPayload is empty")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(decodedPayload, forType: .string)
        showActions = false
        saveToFrecency()
    }

    func copyToken() {
        let token = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        showActions = false
    }

    func saveToFrecency() {
        let token = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            log.debug("saveToFrecency: no token to save")
            return
        }
        log.info("Saving JWT to frecency (\(token.prefix(40))...)")
        appState.recordSelection(query: "", item: SearchItem(
            id: "jwt-decoder",
            title: "JWT Decoder",
            subtitle: "Decode and inspect JSON Web Token",
            icon: "key.viewfinder",
            kind: .jwt,
            meta: ["token": token]
        ))
    }

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if showActions {
                return handleActionsKey(event)
            }

            if event.modifierFlags.contains(.command) && event.characters == "k" {
                guard !currentActions.isEmpty else { return event }
                actionIndex = 0
                showActions.toggle()
                return nil
            }

            let key = event.specialKey
            if key == .carriageReturn || key == .newline {
                copyPayload()
                return nil
            }

            if event.keyCode == 53 {
                appState.panelMode = .search
                return nil
            }

            return event
        }
    }

    private func handleActionsKey(_ event: NSEvent) -> NSEvent? {
        let key = event.specialKey
        if key == .upArrow {
            actionIndex = actionIndex <= 0 ? currentActions.count - 1 : actionIndex - 1
            return nil
        }
        if key == .downArrow {
            actionIndex = actionIndex >= currentActions.count - 1 ? 0 : actionIndex + 1
            return nil
        }
        if key == .carriageReturn || key == .newline {
            if actionIndex < currentActions.count {
                currentActions[actionIndex].action()
            }
            showActions = false
            return nil
        }
        if event.keyCode == 53 {
            showActions = false
            return nil
        }
        return event
    }

    func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    func decodeBase64(_ string: String) -> String {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let length = Double(base64.lengthOfBytes(using: .utf8))
        let requiredLength = 4 * ceil(length / 4.0)
        let paddingLength = requiredLength - length
        if paddingLength > 0 {
            base64 += "".padding(toLength: Int(paddingLength), withPad: "=", startingAt: 0)
        }

        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: json,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return ""
        }

        return prettyString
    }
}

struct JWTAction {
    let label: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
}

// MARK: - Timestamp Tooltips

private struct TimestampAnnotatedText: View {
    let text: String
    let color: Color

    /// Unix timestamps between 2001-01-01 and 2100-01-01
    private static let timestampRange: ClosedRange<Double> = 978_307_200 ... 4_102_444_800

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeStyle = .long
        return fmt
    }()

    private static let timestampPattern = /:\s*(\d{10,13})\b/

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if let tooltip = Self.timestampTooltip(for: line) {
                    Text(line)
                        .help(tooltip)
                } else {
                    Text(line)
                }
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundColor(color)
        .textSelection(.enabled)
    }

    private static func timestampTooltip(for line: String) -> String? {
        guard let match = line.firstMatch(of: timestampPattern),
              let value = Double(match.1)
        else { return nil }

        // Support both seconds (10 digits) and milliseconds (13 digits)
        let seconds = value > 9_999_999_999 ? value / 1000 : value
        guard timestampRange.contains(seconds) else { return nil }

        let date = Date(timeIntervalSince1970: seconds)
        return dateFormatter.string(from: date)
    }
}
