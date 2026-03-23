import AppKit
import os

private let log = Logger(subsystem: "com.relux.app", category: "hotkey-listener")

@MainActor
final class HotkeyListener {
    var onHotkey: ((KeyCombo) -> Void)?

    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private var isRunning = false
    private var context: HotkeyListenerContext?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let ctx = Unmanaged<HotkeyListenerContext>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout {
                if let tap = ctx.tapRef {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passRetained(event)
            }

            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            var modRaw = NSEvent.ModifierFlags()
            if flags.contains(.maskCommand) { modRaw.insert(.command) }
            if flags.contains(.maskAlternate) { modRaw.insert(.option) }
            if flags.contains(.maskControl) { modRaw.insert(.control) }
            if flags.contains(.maskShift) { modRaw.insert(.shift) }

            let combo = KeyCombo(keyCode: keyCode, modifierRawValue: modRaw.rawValue)

            if ctx.registeredKeys.contains(combo.storageKey) {
                DispatchQueue.main.async {
                    ctx.handler?(combo)
                }
                return nil
            }

            return Unmanaged.passRetained(event)
        }

        let ctx = HotkeyListenerContext()
        ctx.handler = { [weak self] combo in
            self?.onHotkey?(combo)
        }
        self.context = ctx

        let ptr = Unmanaged.passRetained(ctx).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: ptr
        ) else {
            log.error("Failed to create CGEvent tap for hotkey listener")
            isRunning = false
            return
        }

        eventTap = tap
        ctx.tapRef = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("Hotkey listener started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let ctx = context {
            Unmanaged.passUnretained(ctx).release()
        }
        eventTap = nil
        runLoopSource = nil
        context = nil
        log.info("Hotkey listener stopped")
    }

    func updateRegisteredKeys(_ keys: Set<String>) {
        context?.registeredKeys = keys
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}

private class HotkeyListenerContext {
    nonisolated(unsafe) var handler: ((KeyCombo) -> Void)?
    nonisolated(unsafe) var registeredKeys: Set<String> = []
    nonisolated(unsafe) var tapRef: CFMachPort?
}
