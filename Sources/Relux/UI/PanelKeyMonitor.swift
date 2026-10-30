import AppKit
import SwiftUI

/// A `keyDown` monitor scoped to the window that hosts this view.
///
/// `NSEvent.addLocalMonitorForEvents` is process-wide, so an unscoped monitor keeps
/// consuming keys for whichever window is key. The overlay panel is only ordered out
/// on dismissal (`NSPanel.isReleasedWhenClosed == false`), which means its SwiftUI
/// views — and their monitors — can outlive the panel. Scoping by `event.window`
/// makes a monitor inert the moment its own window stops receiving events, without
/// depending on `.onDisappear` ever running.
///
/// The handler sees only events delivered to this view's window and returns `nil`
/// for keys it consumed, `event` to pass them on.
struct PanelKeyMonitor: NSViewRepresentable {
    /// The monitor is only installed while this is true, for callers that capture
    /// keys on demand (shortcut recorders) rather than for the view's whole life.
    var isActive: Bool = true
    /// Notifies the caller that the host window is gone (closed or the view was
    /// removed). Lets state that must not outlive the window — notably the global
    /// hotkey suspension — unwind even when `.onDisappear` never fires.
    var onWindowLost: (() -> Void)?
    /// Receives window-scoped key events. Return `nil` to consume the event.
    var handler: (NSEvent) -> NSEvent?

    func makeNSView(context _: Context) -> MonitorHostView {
        MonitorHostView()
    }

    func updateNSView(_ view: MonitorHostView, context _: Context) {
        view.isActive = isActive
        view.onWindowLost = onWindowLost
        view.handler = handler
    }

    static func dismantleNSView(_ view: MonitorHostView, coordinator _: ()) {
        view.tearDown()
    }
}

/// Owns the actual monitor, because only an `NSView` knows its window and its lifetime.
///
/// Retention: the monitor's handler captures `self` weakly, and `self` strongly holds
/// the monitor token and the caller's closures. Nothing the caller passes back can
/// reference this view, so the chain never loops.
final class MonitorHostView: NSView {
    /// Starts inactive so nothing is installed until SwiftUI has supplied the caller's
    /// value in `updateNSView`; `viewDidMoveToWindow` and `updateNSView` may arrive in
    /// either order.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            syncMonitor()
        }
    }

    var onWindowLost: (() -> Void)?
    var handler: ((NSEvent) -> NSEvent?)?

    private var monitor: Any?
    private var windowCloseObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowClose()
        syncMonitor()
    }

    /// Called from `dismantleNSView`; the caller's own teardown path handles unwinding
    /// state, so the callbacks are dropped rather than invoked here.
    func tearDown() {
        removeMonitor()
        removeWindowCloseObserver()
        onWindowLost = nil
        handler = nil
    }

    // No `deinit`: `monitor` is a non-Sendable token that cannot be touched from a
    // nonisolated deinit. Removal is guaranteed by `dismantleNSView`, by the window-close
    // observer, and (harmlessly) by the handler's weak `self`, which turns any orphaned
    // monitor into a pass-through.

    private func syncMonitor() {
        guard isActive, window != nil else {
            removeMonitor()
            return
        }
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window, event.window === window else {
                return event
            }
            guard let handler else { return event }
            return handler(event)
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// A closing window does not remove its views, so neither `viewDidMoveToWindow`
    /// nor `dismantleNSView` is guaranteed to run when the user closes it.
    private func observeWindowClose() {
        removeWindowCloseObserver()
        guard let window else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeMonitor()
                self.onWindowLost?()
            }
        }
    }

    private func removeWindowCloseObserver() {
        guard let windowCloseObserver else { return }
        NotificationCenter.default.removeObserver(windowCloseObserver)
        self.windowCloseObserver = nil
    }
}
