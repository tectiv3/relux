import AppKit
import SwiftUI

@MainActor
final class VolumeHUDController {
    private static let windowSize = NSSize(width: 220, height: 56)
    private static let cornerRadius: CGFloat = 12
    private static let holdDuration: TimeInterval = 1.1
    private static let fadeDuration: TimeInterval = 0.11

    private var window: NSWindow?
    private let hostingView = NSHostingView(
        rootView: VolumeHUDView(snapshot: VolumeSnapshot(value: 0, isMuted: false))
    )
    private var monitor: VolumeMonitor?
    private var lastApplied: VolumeSnapshot?
    private var holdWorkItem: DispatchWorkItem?
    private var fadeWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?

    func start() {
        guard monitor == nil else { return }
        createWindowIfNeeded()
        observeScreenChanges()
        let monitor = VolumeMonitor { [weak self] snapshot in
            self?.apply(snapshot)
        }
        self.monitor = monitor
        monitor.start()
    }

    func stop() {
        cancelPending()
        window?.orderOut(nil)
        window?.alphaValue = 1
        lastApplied = nil
        monitor?.stop()
        monitor = nil
        removeScreenObserver()
    }

    func apply(_ snapshot: VolumeSnapshot) {
        createWindowIfNeeded()
        cancelPending()

        let isUnchanged = snapshot == lastApplied
        let isOnScreen = window?.isVisible == true && window?.alphaValue == 1
        if isUnchanged, isOnScreen {
            scheduleHold()
            return
        }

        lastApplied = snapshot
        hostingView.rootView = VolumeHUDView(snapshot: snapshot)

        guard let window else { return }
        window.alphaValue = 1
        repositionWindow()
        if !window.isVisible {
            window.orderFront(nil)
        }
        scheduleHold()
    }

    // MARK: - Timing

    private func scheduleHold() {
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.beginFade()
            }
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: item)
    }

    private func beginFade() {
        let steps = 10
        scheduleFadeStep(1, steps: steps, stepDuration: Self.fadeDuration / Double(steps))
    }

    private func scheduleFadeStep(_ step: Int, steps: Int, stepDuration: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                window.alphaValue = max(0, 1 - CGFloat(step) / CGFloat(steps))
                if step >= steps {
                    self.fadeWorkItem = nil
                    window.orderOut(nil)
                } else {
                    self.scheduleFadeStep(step + 1, steps: steps, stepDuration: stepDuration)
                }
            }
        }
        fadeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration, execute: item)
    }

    private func cancelPending() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
    }

    // MARK: - Window

    private func createWindowIfNeeded() {
        guard window == nil else { return }
        let rect = NSRect(origin: .zero, size: Self.windowSize)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.alphaValue = 1

        let visualEffect = NSVisualEffectView(frame: rect)
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.maskImage = Self.roundedMask(size: rect.size, radius: Self.cornerRadius)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])
        window.contentView = visualEffect
        self.window = window
    }

    private func repositionWindow() {
        guard let window else { return }
        guard let screen = DisplaySelection.screenUnderMouse() ?? NSScreen.main else { return }
        let frame = screen.frame
        let size = window.frame.size
        let origin = NSPoint(
            x: frame.origin.x + (frame.width - size.width) / 2,
            y: frame.origin.y + frame.height * 0.17
        )
        window.setFrameOrigin(origin)
    }

    // MARK: - Screen changes

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionWindow()
            }
        }
    }

    private func removeScreenObserver() {
        guard let screenObserver else { return }
        NotificationCenter.default.removeObserver(screenObserver)
        self.screenObserver = nil
    }

    private static func roundedMask(size: NSSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
