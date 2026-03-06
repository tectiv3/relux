import AppKit
import SwiftUI

struct JWTView: View {
    @Environment(AppState.self) private var appState
    @State private var inputText: String = ""
    @State private var showActions: Bool = false
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

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 6)
            topBar
            Divider()

            HSplitView {
                rawTokenView
                    .frame(minWidth: 200)
                decodedView
                    .frame(minWidth: 200)
            }

            Spacer(minLength: 0)
            Divider()
            bottomBar
        }
        .frame(width: 750)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if let selection = appState.currentSelection, !selection.isEmpty {
                // Heuristic: if selection contains dots and looks like base64, use it
                if selection.contains(".") && selection.count > 20 {
                    inputText = selection
                }
                appState.currentSelection = nil
            }
            isInputFocused = true
        }
        .onKeyPress(.escape) {
            appState.panelMode = .search
            return .handled
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

            TextField("Enter JWT token...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .focused($isInputFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Content Views

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
                if !decodedHeader.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HEADER: ALGORITHM & TOKEN TYPE")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                        Text(decodedHeader)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                }

                if !decodedPayload.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PAYLOAD: DATA")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                        Text(decodedPayload)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.purple)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button {
                copyPayload()
            } label: {
                keyboardHint(key: "\u{23CE}", label: "Copy Payload JSON")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])

            keyboardHint(key: "esc", label: "Back")
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    private func keyboardHint(key: String, label: String) -> some View {
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

    // MARK: - Actions

    private func copyPayload() {
        guard !decodedPayload.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(decodedPayload, forType: .string)
        
        // Maybe show a toast or flash? For now just done.
        // Could auto-close or go back, but user might want to inspect more.
        // Let's keep it open.
    }

    // MARK: - Helpers

    private func decodeBase64(_ string: String) -> String {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        let length = Double(base64.lengthOfBytes(using: .utf8))
        let requiredLength = 4 * ceil(length / 4.0)
        let paddingLength = requiredLength - length
        if paddingLength > 0 {
            let padding = "".padding(toLength: Int(paddingLength), withPad: "=", startingAt: 0)
            base64 += padding
        }
        
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return ""
        }
        
        return prettyString
    }
}
