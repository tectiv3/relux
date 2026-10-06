import AppKit

@MainActor
enum DisplaySelection {
    /// The screen whose frame contains the mouse cursor, else `NSScreen.main`, else the first screen.
    static func screenUnderMouse() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? screens[0]
    }

    /// The screen whose frame contains `point` (via `NSMouseInRect(point, screen.frame, false)`), or nil.
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Stable identity for comparing screens.
    static func identifier(of screen: NSScreen?) -> CGDirectDisplayID? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
