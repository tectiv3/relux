import AppKit
import SwiftUI

@MainActor
enum Toast {
    private static var window: NSWindow?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ message: String, icon: String = "exclamationmark.triangle") {
        dismissTask?.cancel()
        window?.close()

        guard let screen = NSScreen.main else { return }

        let panel = makePanel(message: message, icon: icon, screen: screen)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        window = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.close()
            }
        }
    }

    private static func makePanel(message: String, icon: String, screen: NSScreen) -> NSPanel {
        let toast = NSHostingView(rootView:
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThickMaterial)
            .clipShape(Capsule()))
        toast.setFrameSize(toast.fittingSize)

        let maxWidth = min(toast.fittingSize.width, 600)
        let size = NSSize(width: maxWidth, height: toast.fittingSize.height)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 40
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.hasShadow = true
        panel.contentView = toast
        panel.alphaValue = 0
        return panel
    }
}
