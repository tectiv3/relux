import AppKit

/// Per-path cache for app icons.
///
/// `NSWorkspace.icon(forFile:)` returns the full representation bundle for an app and was being
/// called inside the row body, so every SwiftUI render re-fetched and re-resampled the icon.
/// Icons are now rasterized once at display resolution and reused for the process lifetime.
///
/// Staleness: keys are paths only, so an app replaced in place at the same path after the cache is
/// populated keeps its old icon until relaunch. Keying on the bundle's modification date would fix
/// that at the cost of a `stat` per render, which is the work this cache exists to remove.
@MainActor
enum AppIconCache {
    /// 24 pt rows at 2x.
    static let pixelSize = 48

    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func icon(forPath path: String) -> NSImage? {
        icon(forPath: path) { NSWorkspace.shared.icon(forFile: $0) }
    }

    /// `fetch` is injectable so tests can count fetches instead of touching `NSWorkspace`.
    static func icon(forPath path: String, fetch: (String) -> NSImage?) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        guard let source = fetch(path) else { return nil }
        let downsampled = downsampled(source, pixels: pixelSize)
        cache.setObject(downsampled, forKey: path as NSString)
        return downsampled
    }

    /// Rasterizes `image` into a `pixels`×`pixels` bitmap whose point size is half that, i.e. 2x.
    /// Drawing into a bitmap rep (rather than keeping a lazily drawn `NSImage`) means the resize
    /// happens once here instead of on every draw.
    static func downsampled(_ image: NSImage, pixels: Int) -> NSImage {
        let pointSize = NSSize(width: pixels / 2, height: pixels / 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return image
        }
        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: pointSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        let result = NSImage(size: pointSize)
        result.addRepresentation(rep)
        return result
    }
}
