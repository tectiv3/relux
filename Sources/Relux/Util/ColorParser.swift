import AppKit

// swiftlint:disable identifier_name
enum ColorParser {
    /// Attempts to parse a trimmed string as a color value.
    /// Supports: #RGB, #RRGGBB, #RRGGBBAA, rgb(), rgba(), hsl(), hsla()
    static func parse(_ input: String) -> NSColor? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isNewline), s.count <= 40 else { return nil }
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
        let inner = s[s.index(after: open) ..< close]
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
        let inner = input[input.index(after: open) ..< close]
        let parts = inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        guard let h = Double(parts[0]),
              let sat = Double(parts[1].replacingOccurrences(of: "%", with: "")),
              let l = Double(parts[2].replacingOccurrences(of: "%", with: "")) else { return nil }
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

// swiftlint:enable identifier_name
