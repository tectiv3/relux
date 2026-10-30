import XCTest

/// `SettingsStore` is compiled into the test bundle through `project.yml` and exercised against a
/// scratch `UserDefaults` suite, so the persisted key strings and defaults are pinned without
/// touching the developer's own defaults.
final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "com.relux.tests.settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        suiteName = ""
        super.tearDown()
    }

    // MARK: - Key strings

    /// The regression guard against a silent rename: every persisted key string is asserted as a
    /// literal, independently of the source constant.
    func testKeyStringsAreUnchanged() {
        let expected: Set = [
            "showMenuBarIcon",
            "hasCompletedSetup",
            "clearQueryOnOpen",
            "maxSearchResults",
            "appAppearance",
            "forceInputSourceId",
            "clipboardEnabled",
            "clipboardRetentionMonths",
            "clipboardDisabledApps",
            "translateModel",
            "translateSystemPrompt",
            "translateLanguages",
            "panelX",
            "panelY",
            "gesture.threeFingerClickEnabled",
            "gesture.stableFrames",
            "gesture.swipeThreshold",
            "gesture.edgeMargin",
            "gesture.keystrokeWindowMs",
            "gesture.touchQualityMin",
            "gesture.fingerSpreadMin",
            "gesture.aspectRatioMax",
            "gesture.bindings",
            "gesture.shortcutBindings",
        ]
        let actual = Set(SettingsStore.DefaultsKey.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, SettingsStore.DefaultsKey.allCases.count)
    }

    func testEveryAccessorUsesItsDeclaredKey() {
        // Each accessor is pinned to the raw key by writing through the store and reading the raw
        // value back, so an accessor pointing at the wrong key cannot pass.
        settings.hasCompletedSetup = true
        XCTAssertEqual(defaults.bool(forKey: "hasCompletedSetup"), true)

        settings.clearQueryOnOpen = true
        XCTAssertEqual(defaults.bool(forKey: "clearQueryOnOpen"), true)

        settings.maxSearchResults = 17
        XCTAssertEqual(defaults.object(forKey: "maxSearchResults") as? Int, 17)

        settings.appAppearance = "dark"
        XCTAssertEqual(defaults.string(forKey: "appAppearance"), "dark")

        settings.forceInputSourceID = "com.apple.keylayout.ABC"
        XCTAssertEqual(defaults.string(forKey: "forceInputSourceId"), "com.apple.keylayout.ABC")

        settings.clipboardEnabled = false
        XCTAssertEqual(defaults.object(forKey: "clipboardEnabled") as? Bool, false)

        settings.clipboardRetentionMonths = 6
        XCTAssertEqual(defaults.object(forKey: "clipboardRetentionMonths") as? Int, 6)

        settings.clipboardDisabledApps = ["com.example.app"]
        XCTAssertEqual(defaults.stringArray(forKey: "clipboardDisabledApps"), ["com.example.app"])

        settings.translateModel = "model-x"
        XCTAssertEqual(defaults.string(forKey: "translateModel"), "model-x")

        settings.translateSystemPrompt = "prompt"
        XCTAssertEqual(defaults.string(forKey: "translateSystemPrompt"), "prompt")

        settings.translateLanguages = ["German"]
        XCTAssertEqual(defaults.stringArray(forKey: "translateLanguages"), ["German"])

        settings.panelOrigin = CGPoint(x: 10, y: 20)
        XCTAssertEqual(defaults.object(forKey: "panelX") as? CGFloat, 10)
        XCTAssertEqual(defaults.object(forKey: "panelY") as? CGFloat, 20)

        settings.gestureThreeFingerClickEnabled = false
        XCTAssertEqual(defaults.object(forKey: "gesture.threeFingerClickEnabled") as? Bool, false)

        settings.gestureStableFrames = 4
        XCTAssertEqual(defaults.object(forKey: "gesture.stableFrames") as? Int, 4)

        settings.gestureSwipeThreshold = Float(0.33)
        XCTAssertEqual(defaults.object(forKey: "gesture.swipeThreshold") as? Float, Float(0.33))

        settings.gestureEdgeMargin = Float(0.07)
        XCTAssertEqual(defaults.object(forKey: "gesture.edgeMargin") as? Float, Float(0.07))

        settings.gestureKeystrokeWindowMs = 250
        XCTAssertEqual(defaults.object(forKey: "gesture.keystrokeWindowMs") as? Int, 250)

        settings.gestureTouchQualityMin = Float(0.25)
        XCTAssertEqual(defaults.object(forKey: "gesture.touchQualityMin") as? Float, Float(0.25))

        settings.gestureFingerSpreadMin = Float(0.3)
        XCTAssertEqual(defaults.object(forKey: "gesture.fingerSpreadMin") as? Float, Float(0.3))

        settings.gestureAspectRatioMax = Float(3.5)
        XCTAssertEqual(defaults.object(forKey: "gesture.aspectRatioMax") as? Float, Float(3.5))

        let bindings = Data([1, 2, 3])
        settings.gestureBindingsData = bindings
        XCTAssertEqual(defaults.data(forKey: "gesture.bindings"), bindings)

        let shortcuts = Data([4, 5, 6])
        settings.gestureShortcutBindingsData = shortcuts
        XCTAssertEqual(defaults.data(forKey: "gesture.shortcutBindings"), shortcuts)
    }

    // MARK: - Registered defaults

    func testRegisterDefaultsMatchesTheOldLaunchDictionary() {
        settings.registerDefaults()

        // Registered values are visible to raw lookups, exactly as before the refactor.
        XCTAssertEqual(defaults.object(forKey: "showMenuBarIcon") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "clipboardEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "clipboardRetentionMonths") as? Int, 3)
        XCTAssertEqual(
            defaults.stringArray(forKey: "clipboardDisabledApps"),
            ["com.apple.keychainaccess", "com.apple.Passwords"]
        )
        XCTAssertEqual(SettingsStore.defaultDisabledClipboardApps, ["com.apple.keychainaccess", "com.apple.Passwords"])
    }

    func testRegisterDefaultsDoesNotLeakIntoOtherKeys() {
        settings.registerDefaults()

        // Keys the app never registered must stay absent so `object(forKey:)` keeps returning nil.
        for key in ["hasCompletedSetup", "maxSearchResults", "appAppearance", "panelX", "gesture.stableFrames"] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should not be registered")
        }
    }

    // MARK: - Defaults before any write

    func testDefaultsBeforeAnyWrite() {
        settings.registerDefaults()

        XCTAssertEqual(settings.showMenuBarIcon, true)
        XCTAssertEqual(settings.hasCompletedSetup, false)
        XCTAssertEqual(settings.isFirstRun, true)
        XCTAssertEqual(settings.clearQueryOnOpen, false)
        XCTAssertEqual(settings.maxSearchResults, 10)
        XCTAssertEqual(settings.appAppearance, "system")
        XCTAssertEqual(settings.forceInputSourceID, "")
        XCTAssertEqual(settings.clipboardEnabled, true)
        XCTAssertEqual(settings.clipboardRetentionMonths, 3)
        XCTAssertEqual(settings.clipboardDisabledApps, ["com.apple.keychainaccess", "com.apple.Passwords"])
        XCTAssertNil(settings.translateModel)
        XCTAssertNil(settings.translateSystemPrompt)
        XCTAssertEqual(settings.translateLanguages, ["English"])
        XCTAssertNil(settings.panelOrigin)
        XCTAssertEqual(settings.gestureThreeFingerClickEnabled, true)
        XCTAssertEqual(settings.gestureStableFrames, 2)
        XCTAssertEqual(settings.gestureSwipeThreshold, Float(0.15))
        XCTAssertEqual(settings.gestureEdgeMargin, Float(0.05))
        XCTAssertEqual(settings.gestureKeystrokeWindowMs, 180)
        XCTAssertEqual(settings.gestureTouchQualityMin, Float(0.125))
        XCTAssertEqual(settings.gestureFingerSpreadMin, Float(0.15))
        XCTAssertEqual(settings.gestureAspectRatioMax, Float(2.5))
        XCTAssertNil(settings.gestureBindingsData)
        XCTAssertNil(settings.gestureShortcutBindingsData)
    }

    /// Same expectations without `registerDefaults()`, which is what the test scratch suite and any
    /// code running before launch registration sees.
    func testDefaultsBeforeAnyWriteWithoutRegistration() {
        XCTAssertEqual(settings.showMenuBarIcon, true)
        XCTAssertEqual(settings.clipboardEnabled, true)
        XCTAssertEqual(settings.clipboardRetentionMonths, 3)
        XCTAssertEqual(settings.clipboardDisabledApps, ["com.apple.keychainaccess", "com.apple.Passwords"])
    }

    // MARK: - Round trips

    func testBoolRoundTrip() {
        for value in [false, true, false] {
            settings.showMenuBarIcon = value
            XCTAssertEqual(settings.showMenuBarIcon, value)
            settings.hasCompletedSetup = value
            XCTAssertEqual(settings.hasCompletedSetup, value)
            settings.clearQueryOnOpen = value
            XCTAssertEqual(settings.clearQueryOnOpen, value)
            settings.clipboardEnabled = value
            XCTAssertEqual(settings.clipboardEnabled, value)
            settings.gestureThreeFingerClickEnabled = value
            XCTAssertEqual(settings.gestureThreeFingerClickEnabled, value)
        }
    }

    func testIntRoundTrip() {
        settings.maxSearchResults = 5
        XCTAssertEqual(settings.maxSearchResults, 5)
        settings.maxSearchResults = 20
        XCTAssertEqual(settings.maxSearchResults, 20)

        settings.clipboardRetentionMonths = 1
        XCTAssertEqual(settings.clipboardRetentionMonths, 1)
        settings.clipboardRetentionMonths = 6
        XCTAssertEqual(settings.clipboardRetentionMonths, 6)

        settings.gestureStableFrames = 8
        XCTAssertEqual(settings.gestureStableFrames, 8)

        settings.gestureKeystrokeWindowMs = 500
        XCTAssertEqual(settings.gestureKeystrokeWindowMs, 500)
        settings.gestureKeystrokeWindowMs = 0
        XCTAssertEqual(settings.gestureKeystrokeWindowMs, 0)
    }

    func testFloatRoundTripIsExact() {
        for value in [Float(0.05), 0.15, 0.40] {
            settings.gestureSwipeThreshold = value
            XCTAssertEqual(settings.gestureSwipeThreshold, value)
        }
        for value in [Float(0.0), 0.15] {
            settings.gestureEdgeMargin = value
            XCTAssertEqual(settings.gestureEdgeMargin, value)
        }
        for value in [Float(0.0), 0.5] {
            settings.gestureTouchQualityMin = value
            XCTAssertEqual(settings.gestureTouchQualityMin, value)
        }
        for value in [Float(0.0), 0.4] {
            settings.gestureFingerSpreadMin = value
            XCTAssertEqual(settings.gestureFingerSpreadMin, value)
        }
        for value in [Float(1.5), 2.5, 5.0] {
            settings.gestureAspectRatioMax = value
            XCTAssertEqual(settings.gestureAspectRatioMax, value)
        }
    }

    func testStringRoundTrips() {
        settings.appAppearance = "dark"
        XCTAssertEqual(settings.appAppearance, "dark")
        settings.appAppearance = "light"
        XCTAssertEqual(settings.appAppearance, "light")

        settings.translateModel = "claude-x"
        XCTAssertEqual(settings.translateModel, "claude-x")
        settings.translateModel = nil
        XCTAssertNil(settings.translateModel)

        settings.translateSystemPrompt = "be terse"
        XCTAssertEqual(settings.translateSystemPrompt, "be terse")
        settings.translateSystemPrompt = nil
        XCTAssertNil(settings.translateSystemPrompt)
        XCTAssertNil(defaults.object(forKey: "translateSystemPrompt"))
    }

    func testEmptyForceInputSourceRemovesTheKey() {
        settings.forceInputSourceID = "com.apple.keylayout.ABC"
        XCTAssertEqual(defaults.string(forKey: "forceInputSourceId"), "com.apple.keylayout.ABC")

        settings.forceInputSourceID = ""
        XCTAssertNil(defaults.object(forKey: "forceInputSourceId"))
        XCTAssertEqual(settings.forceInputSourceID, "")
    }

    func testArrayAndSetRoundTrips() {
        settings.translateLanguages = ["German", "English"]
        XCTAssertEqual(settings.translateLanguages, ["German", "English"])

        settings.clipboardDisabledApps = ["com.example.a", "com.example.b"]
        XCTAssertEqual(settings.clipboardDisabledApps, ["com.example.a", "com.example.b"])
        settings.clipboardDisabledApps = []
        XCTAssertEqual(settings.clipboardDisabledApps, [])
        XCTAssertEqual(defaults.stringArray(forKey: "clipboardDisabledApps"), [])
    }

    func testPanelOriginRoundTrip() {
        settings.panelOrigin = CGPoint(x: 123.5, y: -456.25)
        XCTAssertEqual(settings.panelOrigin, CGPoint(x: 123.5, y: -456.25))

        settings.panelOrigin = CGPoint(x: 0, y: 0)
        XCTAssertEqual(settings.panelOrigin, CGPoint(x: 0, y: 0))

        settings.panelOrigin = nil
        XCTAssertNil(settings.panelOrigin)
        XCTAssertNil(defaults.object(forKey: "panelX"))
        XCTAssertNil(defaults.object(forKey: "panelY"))
    }

    func testPanelOriginIsNilWhenOnlyOneCoordinateWasSaved() {
        defaults.set(10.0, forKey: "panelX")
        XCTAssertNil(settings.panelOrigin)
    }

    // MARK: - Validation

    func testGestureStableFramesClampsToOne() {
        defaults.set(0, forKey: "gesture.stableFrames")
        XCTAssertEqual(settings.gestureStableFrames, 1)
        defaults.set(-5, forKey: "gesture.stableFrames")
        XCTAssertEqual(settings.gestureStableFrames, 1)
    }

    func testGestureKeystrokeWindowClampsToZero() {
        defaults.set(-120, forKey: "gesture.keystrokeWindowMs")
        XCTAssertEqual(settings.gestureKeystrokeWindowMs, 0)
    }

    // MARK: - Injection

    func testScratchSuitePersistence() throws {
        settings.maxSearchResults = 12

        let other = try SettingsStore(defaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
        XCTAssertEqual(other.maxSearchResults, 12)
    }
}
