import AppKit
import os
import ReluxCore
import SwiftUI

private let log = Logger(subsystem: "com.relux.app", category: "jwt")

struct JWTView: View {
    @Environment(AppState.self) private var appState
    @State private var inputText: String = ""
    @State private var menu = ActionSelection()
    @FocusState private var isInputFocused: Bool

    private var tokenParts: JWTParts {
        JWTParser.parts(of: inputText)
    }

    private var headerPart: String {
        tokenParts.header
    }

    private var payloadPart: String {
        tokenParts.payload
    }

    private var signaturePart: String {
        tokenParts.signature
    }

    private var decodedHeader: String {
        JWTParser.decodedSegment(headerPart)
    }

    private var decodedPayload: String {
        JWTParser.decodedSegment(payloadPart)
    }

    private var isValidJWT: Bool {
        tokenParts.isValid
    }

    private var expiryBadge: JWTExpiryBadge? {
        guard isValidJWT else { return nil }
        return JWTParser.claims(ofToken: inputText)?.expiryBadge()
    }

    private var currentActions: [Action] {
        guard isValidJWT else { return [] }
        return PanelActions.jwt().map { descriptor in
            Action(descriptor) {
                switch descriptor.kind {
                case .copyPayload: copyPayload()
                case .copyToken: copyToken()
                default: break
                }
            }
        }
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
            if menu.isOpen {
                ActionOverlay(
                    actions: currentActions,
                    selectedIndex: menu.index,
                    width: 220,
                    onSelect: runAction,
                    header: { EmptyView() }
                )
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
        }
        .onChange(of: appState.selectionCaptureID) { _, _ in
            // Selection captured asynchronously after the view appeared
            if inputText.isEmpty, let selection = appState.currentSelection, !selection.isEmpty {
                inputText = selection
                appState.currentSelection = nil
                saveToFrecency()
            }
        }
        .background(PanelKeyMonitor(handler: handlePanelKey))
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

            if let expiryBadge {
                expiryBadgeView(expiryBadge)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func expiryBadgeView(_ badge: JWTExpiryBadge) -> some View {
        Text(badge.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(badge.tone.color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(badge.tone.color.opacity(0.12))
            )
            .fixedSize()
            .help(badge.detail)
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
            if menu.isOpen {
                KeyboardHint(key: "\u{23CE}", label: "Select")
                KeyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                KeyboardHint(key: "esc", label: "Back")
            } else {
                KeyboardHint(key: "\u{23CE}", label: "Copy Payload")
                KeyboardHint(key: "\u{2318}K", label: "Actions")
                KeyboardHint(key: "esc", label: "Back")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    func runAction(_ index: Int) {
        let actions = currentActions
        if index >= 0, index < actions.count {
            actions[index].handler()
        }
        // The JWT menu closes on Return even when the cursor has no row, matching the old handler.
        menu.close()
    }

    func copyPayload() {
        guard !decodedPayload.isEmpty else {
            log.debug("copyPayload: decodedPayload is empty")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(decodedPayload, forType: .string)
        menu.close()
        saveToFrecency()
    }

    func copyToken() {
        let token = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        menu.close()
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

    /// Only keys this view consumed are swallowed; everything else is passed on.
    private func handlePanelKey(_ event: NSEvent) -> NSEvent? {
        if menu.isOpen {
            return handleActionsKey(event)
        }

        if event.modifierFlags.contains(.command) && event.characters == "k" {
            guard !currentActions.isEmpty else { return event }
            menu.toggle(isAvailable: true)
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

    private func handleActionsKey(_ event: NSEvent) -> NSEvent? {
        let key = event.specialKey
        if key == .upArrow {
            guard menu.moveUp(count: currentActions.count) else { return event }
            return nil
        }
        if key == .downArrow {
            guard menu.moveDown(count: currentActions.count) else { return event }
            return nil
        }
        if key == .carriageReturn || key == .newline {
            runAction(menu.index)
            return nil
        }
        if event.keyCode == 53 {
            menu.close()
            return nil
        }
        return event
    }
}

private extension JWTExpiryTone {
    var color: Color {
        switch self {
        case .neutral:
            .secondary
        case .warning:
            .orange
        case .critical:
            .red
        }
    }
}

// MARK: - Timestamp Tooltips

private struct TimestampAnnotatedText: View {
    let text: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if let tooltip = JWTParser.timestampTooltip(forLine: line) {
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
}
