import AppKit
import XCTest

@MainActor
final class AppIconCacheTests: XCTestCase {
    /// A solid-colour source icon with known pixel dimensions, standing in for a 512 pt app icon.
    private func sourceIcon(pixels: Int = 512) -> NSImage {
        let rep = NSBitmapImageRep(
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
        )!
        rep.size = NSSize(width: pixels, height: pixels)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.addRepresentation(rep)
        return image
    }

    func testDownsampleProduces48PixelBitmapAtHalfPointSize() {
        let result = AppIconCache.downsampled(sourceIcon(), pixels: AppIconCache.pixelSize)

        guard let rep = result.representations.first as? NSBitmapImageRep else {
            return XCTFail("downsampled icon has no bitmap representation")
        }
        XCTAssertEqual(rep.pixelsWide, 48)
        XCTAssertEqual(rep.pixelsHigh, 48)
        XCTAssertEqual(result.size.width, 24)
        XCTAssertEqual(result.size.height, 24)
    }

    func testIconIsFetchedOncePerPath() {
        let path = "/fake/\(UUID().uuidString).app"
        var fetches = 0
        let fetch: (String) -> NSImage? = { _ in
            fetches += 1
            return self.sourceIcon()
        }

        let first = AppIconCache.icon(forPath: path, fetch: fetch)
        let second = AppIconCache.icon(forPath: path, fetch: fetch)
        let third = AppIconCache.icon(forPath: path, fetch: fetch)

        XCTAssertEqual(fetches, 1)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertTrue(second === third)
        XCTAssertEqual(first?.representations.first?.pixelsWide, 48)
    }

    func testDistinctPathsAreCachedSeparately() {
        var fetchedPaths: [String] = []
        let fetch: (String) -> NSImage? = { path in
            fetchedPaths.append(path)
            return self.sourceIcon()
        }

        let firstPath = "/fake/\(UUID().uuidString).app"
        let secondPath = "/fake/\(UUID().uuidString).app"
        _ = AppIconCache.icon(forPath: firstPath, fetch: fetch)
        _ = AppIconCache.icon(forPath: secondPath, fetch: fetch)
        _ = AppIconCache.icon(forPath: firstPath, fetch: fetch)

        XCTAssertEqual(fetchedPaths, [firstPath, secondPath])
    }

    func testMissingIconIsNotCached() {
        let path = "/fake/\(UUID().uuidString).app"
        var fetches = 0
        let missing: (String) -> NSImage? = { _ in
            fetches += 1
            return nil
        }

        XCTAssertNil(AppIconCache.icon(forPath: path, fetch: missing))
        XCTAssertNil(AppIconCache.icon(forPath: path, fetch: missing))
        // A nil result must not be cached as a permanent "no icon" — a later fetch may succeed.
        XCTAssertNil(AppIconCache.cache.object(forKey: path as NSString))
        XCTAssertEqual(fetches, 2)
    }

    /// Exercises the real provider (`NSWorkspace.icon(forFile:)`) end to end, headlessly.
    func testRealWorkspaceFetchIsDownsampledTo48Pixels() throws {
        let path = "/System/Applications/Utilities/Terminal.app"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "Terminal.app not installed")

        let icon = try XCTUnwrap(AppIconCache.icon(forPath: path))
        let rep = try XCTUnwrap(icon.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, 48)
        XCTAssertEqual(rep.pixelsHigh, 48)
        XCTAssertEqual(icon.size.width, 24)
        XCTAssertTrue(AppIconCache.icon(forPath: path) === icon)
    }
}
