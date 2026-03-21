# Color Parsing in Clipboard History — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers-extended-cc:subagent-driven-development (if subagents available) or superpowers-extended-cc:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect color strings in clipboard entries and display a visual color swatch in both the list row and preview panel, similar to Raycast.

**Architecture:** A standalone `ColorParser` utility parses trimmed text into `NSColor` (hex and CSS function formats). The view layer calls it on `textContent` to conditionally render color swatches instead of text icons/previews. No model or database changes needed.

**Tech Stack:** Swift, SwiftUI, AppKit (NSColor)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/Relux/Util/ColorParser.swift` | Create | Parse color strings → `NSColor?` |
| `Sources/Relux/UI/ClipboardHistoryView.swift` | Modify | Render color swatch in row icon, preview panel, and info footer |
| `project.yml` | Verify | Ensure new file is included (glob pattern should pick it up) |

---

### Task 1: Create ColorParser utility

**Files:**
- Create: `Sources/Relux/Util/ColorParser.swift`

- [ ] **Step 1: Create ColorParser with hex parsing**

```swift
import AppKit

enum ColorParser {
    /// Attempts to parse a trimmed string as a color value.
    /// Supports: #RGB, #RRGGBB, #RRGGBBAA, rgb(), rgba(), hsl(), hsla()
    static func parse(_ input: String) -> NSColor? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") {
            return parseHex(s)
        }
        let lower = s.lowercased()
        if lower.hasPrefix("rgb") {
            return parseRGB(lower)
        }
        if lower.hasPrefix("hsl") {
            return parseHSL(lower)
        }
        return nil
    }

    private static func parseHex(_ hex: String) -> NSColor? {
        var h = hex
        h.removeFirst() // drop #
        let scanner = Scanner(string: h)
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value), scanner.isAtEnd else { return nil }
        switch h.count {
        case 3: // #RGB
            let r = CGFloat((value >> 8) & 0xF) / 15
            let g = CGFloat((value >> 4) & 0xF) / 15
            let b = CGFloat(value & 0xF) / 15
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case 6: // #RRGGBB
            let r = CGFloat((value >> 16) & 0xFF) / 255
            let g = CGFloat((value >> 8) & 0xFF) / 255
            let b = CGFloat(value & 0xFF) / 255
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case 8: // #RRGGBBAA
            let r = CGFloat((value >> 24) & 0xFF) / 255
            let g = CGFloat((value >> 16) & 0xFF) / 255
            let b = CGFloat((value >> 8) & 0xFF) / 255
            let a = CGFloat(value & 0xFF) / 255
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }

    private static func parseRGB(_ s: String) -> NSColor? {
        // rgb(255, 128, 0) or rgba(255, 128, 0, 0.5)
        guard let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")") else { return nil }
        let inner = s[s.index(after: open)..<close]
        let parts = inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        guard let r = Double(parts[0]),
              let g = Double(parts[1]),
              let b = Double(parts[2]) else { return nil }
        let a = parts.count == 4 ? (Double(parts[3]) ?? 1) : 1
        // CSS spec: rgb() values are 0-255
        return NSColor(
            srgbRed: CGFloat(r / 255),
            green: CGFloat(g / 255),
            blue: CGFloat(b / 255),
            alpha: CGFloat(a)
        )
    }

    private static func parseHSL(_ input: String) -> NSColor? {
        // hsl(360, 100%, 50%) or hsla(360, 100%, 50%, 0.5)
        guard let open = input.firstIndex(of: "("),
              let close = input.lastIndex(of: ")") else { return nil }
        let inner = input[input.index(after: open)..<close]
        let parts = inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
        }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        guard let h = Double(parts[0]),
              let sat = Double(parts[1]),
              let l = Double(parts[2]) else { return nil }
        let a = parts.count == 4 ? (Double(parts[3]) ?? 1) : 1
        let sNorm = sat / 100
        let lNorm = l / 100
        return NSColor(
            hue: CGFloat(h / 360),
            saturation: CGFloat(hslToSaturation(s: sNorm, l: lNorm)),
            brightness: CGFloat(hslToBrightness(s: sNorm, l: lNorm)),
            alpha: CGFloat(a)
        )
    }

    /// Convert HSL saturation+lightness to HSB brightness
    private static func hslToBrightness(s: Double, l: Double) -> Double {
        l + s * min(l, 1 - l)
    }

    /// Convert HSL to HSB saturation
    private static func hslToSaturation(s: Double, l: Double) -> Double {
        let b = hslToBrightness(s: s, l: l)
        return b > 0 ? 2 * (1 - l / b) : 0
    }
}

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Relux/Util/ColorParser.swift
git commit -m "feat: add ColorParser utility for hex and CSS color detection"
```

---

### Task 2: Add color swatch to list row

**Files:**
- Modify: `Sources/Relux/UI/ClipboardHistoryView.swift:236-257` (entryRow)

- [ ] **Step 1: Modify entryRow to show color circle**

Replace the `Image(systemName:)` icon in `entryRow` with a conditional: if the entry text parses as a color, show a filled `Circle` with that color; otherwise show the SF Symbol as before.

```swift
// In entryRow(), replace the Image(systemName:) block with:
if let text = entry.textContent, let nsColor = ColorParser.parse(text) {
    Circle()
        .fill(Color(nsColor: nsColor))
        .frame(width: 16, height: 16)
        .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
        .frame(width: 20)
} else {
    Image(systemName: entryIcon(for: entry))
        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
        .font(.system(size: 13))
        .frame(width: 20)
}
```

- [ ] **Step 2: Build and verify**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Relux/UI/ClipboardHistoryView.swift
git commit -m "feat: show color swatch circle in clipboard row for color entries"
```

---

### Task 3: Add color preview to detail panel

**Files:**
- Modify: `Sources/Relux/UI/ClipboardHistoryView.swift:345-374` (previewPanel)

- [ ] **Step 1: Add color preview branch in previewPanel**

Insert a new branch before the text branch in the `ScrollView` content. When text parses as a color, show a large centered circle swatch with the color string below it.

```swift
// Add this branch after the image branch and before the text branch:
} else if let text = entry.textContent, let nsColor = ColorParser.parse(text) {
    VStack(spacing: 16) {
        Spacer()
        Circle()
            .fill(Color(nsColor: nsColor))
            .frame(width: 120, height: 120)
            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
            .shadow(color: Color(nsColor: nsColor).opacity(0.4), radius: 12)
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: 15, design: .monospaced))
            .foregroundColor(.secondary)
        Spacer()
    }
    .frame(maxWidth: .infinity)
```

- [ ] **Step 2: Update infoFooter content type for colors**

In `infoFooter`, modify the "Content type" row to show "Color" when the entry is a color:

```swift
// Replace the content type infoRow with:
infoRow(label: "Content type") {
    if let text = entry.textContent, ColorParser.parse(text) != nil {
        Text("Color")
    } else {
        Text(entry.contentType.capitalized)
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Manual test**

1. Copy a color string like `#FF5733` to clipboard
2. Open Relux clipboard history
3. Verify: circle swatch in row, large preview with color circle and hex string, "Color" in info footer

- [ ] **Step 5: Commit**

```bash
git add Sources/Relux/UI/ClipboardHistoryView.swift
git commit -m "feat: add color preview panel and Color content type label"
```
