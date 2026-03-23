import AppKit

enum GestureType: String, Codable, CaseIterable, Sendable {
    case threeFingerSwipeUp
    case threeFingerSwipeDown
    case threeFingerSwipeLeft
    case threeFingerSwipeRight
    case threeFingerClick

    var displayName: String {
        switch self {
        case .threeFingerSwipeUp: "3-Finger Swipe Up"
        case .threeFingerSwipeDown: "3-Finger Swipe Down"
        case .threeFingerSwipeLeft: "3-Finger Swipe Left"
        case .threeFingerSwipeRight: "3-Finger Swipe Right"
        case .threeFingerClick: "3-Finger Click"
        }
    }
}

struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifierRawValue: UInt

    var modifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: modifierRawValue) }
        set { modifierRawValue = newValue.rawValue }
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("\u{2303}") }
        if modifiers.contains(.option) { parts.append("\u{2325}") }
        if modifiers.contains(.shift) { parts.append("\u{21E7}") }
        if modifiers.contains(.command) { parts.append("\u{2318}") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "\u{21A9}" // Return
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "\u{21E5}" // Tab
        case 49: "\u{2423}" // Space
        case 50: "`"
        case 51: "\u{232B}" // Delete
        case 53: "\u{238B}" // Escape
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 105: "F13"
        case 107: "F14"
        case 109: "F10"
        case 111: "F12"
        case 113: "F15"
        case 118: "F4"
        case 120: "F2"
        case 122: "F1"
        case 123: "\u{2190}" // Left
        case 124: "\u{2192}" // Right
        case 125: "\u{2193}" // Down
        case 126: "\u{2191}" // Up
        default: "Key\(keyCode)"
        }
    }
}

enum SystemAction: String, Codable, CaseIterable, Sendable {
    case lockScreen
    case missionControl
    case appExpose
    case showDesktop

    var displayName: String {
        switch self {
        case .lockScreen: "Lock Screen"
        case .missionControl: "Mission Control"
        case .appExpose: "App Expose"
        case .showDesktop: "Show Desktop"
        }
    }
}

enum ReluxAction: String, Codable, CaseIterable, Sendable {
    case toggleRelux
    case clipboardHistory
    case translate

    var displayName: String {
        switch self {
        case .toggleRelux: "Toggle Relux"
        case .clipboardHistory: "Clipboard History"
        case .translate: "Translate"
        }
    }
}

enum GestureActionType: Codable, Sendable {
    case keyCombo(KeyCombo)
    case system(SystemAction)
    case relux(ReluxAction)
    case none

    var pickerTag: String {
        switch self {
        case .keyCombo: "keyCombo"
        case .system: "system"
        case .relux: "relux"
        case .none: "none"
        }
    }
}

struct GestureBinding: Codable, Sendable {
    var gesture: GestureType
    var action: GestureActionType
}
