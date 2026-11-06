import CoreGraphics
import Foundation

/// Typed accessors over every `UserDefaults` key the app persists.
///
/// Each accessor reproduces the exact read the call site used before (`object(forKey:) as? Bool`,
/// `bool(forKey:)`, `stringArray(forKey:)`, ...) so absent keys keep yielding the same value they
/// always did. Only the keys listed in `registerDefaults()` are registered here — registering more
/// would change what `object(forKey:)` returns for unset keys, so that list grows only when a key
/// needs a default visible to raw lookups.
final class SettingsStore {
    enum DefaultsKey: String, CaseIterable {
        case showMenuBarIcon
        case hasCompletedSetup
        case clearQueryOnOpen
        case maxSearchResults
        case appSearchPaths
        case appAppearance
        case forceInputSourceId
        case clipboardEnabled
        case clipboardRetentionMonths
        case clipboardDisabledApps
        case clipboardOnlySelectionApps
        case translateModel
        case translateSystemPrompt
        case translateLanguages
        case panelX
        case panelY
        case gestureThreeFingerClickEnabled = "gesture.threeFingerClickEnabled"
        case gestureStableFrames = "gesture.stableFrames"
        case gestureSwipeThreshold = "gesture.swipeThreshold"
        case gestureEdgeMargin = "gesture.edgeMargin"
        case gestureKeystrokeWindowMs = "gesture.keystrokeWindowMs"
        case gestureTouchQualityMin = "gesture.touchQualityMin"
        case gestureFingerSpreadMin = "gesture.fingerSpreadMin"
        case gestureAspectRatioMax = "gesture.aspectRatioMax"
        case gestureBindings = "gesture.bindings"
        case gestureShortcutBindings = "gesture.shortcutBindings"
    }

    static let defaultDisabledClipboardApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    /// Apps whose selection must be captured via a synthesized ⌘C instead of an AX read: Chromium
    /// browsers (AXEnhancedUserInterface interferes) plus other non-AX toolkits (Telegram). Seeded
    /// as the default so an existing user keeps the routing they had before the list was editable.
    static let defaultClipboardOnlySelectionApps = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.nickvision.nicegab",
        "org.chromium.Chromium",
        "ru.keepcoder.Telegram",
    ]

    /// Directories `AppSearcher` scans for app bundles. Computed once per process, as it always
    /// was, because `NSHomeDirectory()` is part of the default and callers compare arrays.
    static let defaultAppSearchPaths: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Mirrors the dictionary `AppDelegate` used to register ad hoc at launch.
    func registerDefaults() {
        defaults.register(defaults: [
            DefaultsKey.showMenuBarIcon.rawValue: true,
            DefaultsKey.clipboardEnabled.rawValue: true,
            DefaultsKey.clipboardRetentionMonths.rawValue: 3,
            DefaultsKey.clipboardDisabledApps.rawValue: Self.defaultDisabledClipboardApps,
            DefaultsKey.clipboardOnlySelectionApps.rawValue: Self.defaultClipboardOnlySelectionApps,
        ])
    }

    // MARK: - General

    var showMenuBarIcon: Bool {
        get { defaults.object(forKey: DefaultsKey.showMenuBarIcon.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DefaultsKey.showMenuBarIcon.rawValue) }
    }

    var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: DefaultsKey.hasCompletedSetup.rawValue) }
        set { defaults.set(newValue, forKey: DefaultsKey.hasCompletedSetup.rawValue) }
    }

    var isFirstRun: Bool {
        !hasCompletedSetup
    }

    var clearQueryOnOpen: Bool {
        get { defaults.bool(forKey: DefaultsKey.clearQueryOnOpen.rawValue) }
        set { defaults.set(newValue, forKey: DefaultsKey.clearQueryOnOpen.rawValue) }
    }

    var maxSearchResults: Int {
        get { defaults.object(forKey: DefaultsKey.maxSearchResults.rawValue) as? Int ?? 10 }
        set { defaults.set(newValue, forKey: DefaultsKey.maxSearchResults.rawValue) }
    }

    var appSearchPaths: [String] {
        get { defaults.stringArray(forKey: DefaultsKey.appSearchPaths.rawValue) ?? Self.defaultAppSearchPaths }
        set { defaults.set(newValue, forKey: DefaultsKey.appSearchPaths.rawValue) }
    }

    var appAppearance: String {
        get { defaults.string(forKey: DefaultsKey.appAppearance.rawValue) ?? "system" }
        set { defaults.set(newValue, forKey: DefaultsKey.appAppearance.rawValue) }
    }

    /// Empty means "don't force a layout"; the key is removed rather than stored as "".
    var forceInputSourceID: String {
        get { defaults.string(forKey: DefaultsKey.forceInputSourceId.rawValue) ?? "" }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: DefaultsKey.forceInputSourceId.rawValue)
            } else {
                defaults.set(newValue, forKey: DefaultsKey.forceInputSourceId.rawValue)
            }
        }
    }

    // MARK: - Clipboard

    var clipboardEnabled: Bool {
        get { defaults.object(forKey: DefaultsKey.clipboardEnabled.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DefaultsKey.clipboardEnabled.rawValue) }
    }

    var clipboardRetentionMonths: Int {
        get { defaults.object(forKey: DefaultsKey.clipboardRetentionMonths.rawValue) as? Int ?? 3 }
        set { defaults.set(newValue, forKey: DefaultsKey.clipboardRetentionMonths.rawValue) }
    }

    var clipboardDisabledApps: Set<String> {
        get {
            Set(defaults.stringArray(forKey: DefaultsKey.clipboardDisabledApps.rawValue)
                ?? Self.defaultDisabledClipboardApps)
        }
        set { defaults.set(Array(newValue), forKey: DefaultsKey.clipboardDisabledApps.rawValue) }
    }

    var clipboardOnlySelectionApps: Set<String> {
        get {
            Set(defaults.stringArray(forKey: DefaultsKey.clipboardOnlySelectionApps.rawValue)
                ?? Self.defaultClipboardOnlySelectionApps)
        }
        set { defaults.set(Array(newValue), forKey: DefaultsKey.clipboardOnlySelectionApps.rawValue) }
    }

    // MARK: - Translate

    /// `nil` when unset: the caller falls back to `AnthropicService.defaultModel`, which stays the
    /// single source of that default.
    var translateModel: String? {
        get { defaults.string(forKey: DefaultsKey.translateModel.rawValue) }
        set { setOrRemove(newValue, forKey: .translateModel) }
    }

    /// `nil` when unset: the caller falls back to `AnthropicService.defaultSystemPrompt`.
    var translateSystemPrompt: String? {
        get { defaults.string(forKey: DefaultsKey.translateSystemPrompt.rawValue) }
        set { setOrRemove(newValue, forKey: .translateSystemPrompt) }
    }

    var translateLanguages: [String] {
        get { defaults.stringArray(forKey: DefaultsKey.translateLanguages.rawValue) ?? ["English"] }
        set { defaults.set(newValue, forKey: DefaultsKey.translateLanguages.rawValue) }
    }

    // MARK: - Panel Placement

    /// Both coordinates travel together; the pair is incomplete until the panel has been closed once.
    var panelOrigin: CGPoint? {
        get {
            guard let originX = defaults.object(forKey: DefaultsKey.panelX.rawValue) as? CGFloat,
                  let originY = defaults.object(forKey: DefaultsKey.panelY.rawValue) as? CGFloat
            else { return nil }
            return CGPoint(x: originX, y: originY)
        }
        set {
            guard let origin = newValue else {
                defaults.removeObject(forKey: DefaultsKey.panelX.rawValue)
                defaults.removeObject(forKey: DefaultsKey.panelY.rawValue)
                return
            }
            defaults.set(origin.x, forKey: DefaultsKey.panelX.rawValue)
            defaults.set(origin.y, forKey: DefaultsKey.panelY.rawValue)
        }
    }

    // MARK: - Gestures

    var gestureThreeFingerClickEnabled: Bool {
        get {
            defaults.object(forKey: DefaultsKey.gestureThreeFingerClickEnabled.rawValue) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: DefaultsKey.gestureThreeFingerClickEnabled.rawValue) }
    }

    /// Clamped to >= 1 here rather than in the engine, so the rule is testable.
    var gestureStableFrames: Int {
        get {
            max(1, defaults.object(forKey: DefaultsKey.gestureStableFrames.rawValue) as? Int ?? 2)
        }
        set { defaults.set(newValue, forKey: DefaultsKey.gestureStableFrames.rawValue) }
    }

    var gestureSwipeThreshold: Float {
        get { defaults.object(forKey: DefaultsKey.gestureSwipeThreshold.rawValue) as? Float ?? 0.15 }
        set { defaults.set(newValue, forKey: DefaultsKey.gestureSwipeThreshold.rawValue) }
    }

    var gestureEdgeMargin: Float {
        get { defaults.object(forKey: DefaultsKey.gestureEdgeMargin.rawValue) as? Float ?? 0.05 }
        set { defaults.set(newValue, forKey: DefaultsKey.gestureEdgeMargin.rawValue) }
    }

    /// Negative values are clamped to 0 (suppression disabled) rather than in the engine.
    var gestureKeystrokeWindowMs: Int {
        get {
            max(0, defaults.object(forKey: DefaultsKey.gestureKeystrokeWindowMs.rawValue) as? Int ?? 180)
        }
        set { defaults.set(newValue, forKey: DefaultsKey.gestureKeystrokeWindowMs.rawValue) }
    }

    var gestureTouchQualityMin: Float {
        get { defaults.object(forKey: DefaultsKey.gestureTouchQualityMin.rawValue) as? Float ?? 0.125 }
        set { defaults.set(newValue, forKey: DefaultsKey.gestureTouchQualityMin.rawValue) }
    }

    var gestureFingerSpreadMin: Float {
        get { defaults.object(forKey: DefaultsKey.gestureFingerSpreadMin.rawValue) as? Float ?? 0.15 }
        set { defaults.set(newValue, forKey: DefaultsKey.gestureFingerSpreadMin.rawValue) }
    }

    var gestureAspectRatioMax: Float {
        get { defaults.object(forKey: DefaultsKey.gestureAspectRatioMax.rawValue) as? Float ?? 2.5 }
        set { defaults.set(newValue, forKey: DefaultsKey.gestureAspectRatioMax.rawValue) }
    }

    /// JSON-encoded `[GestureBinding]`; `nil` means "no saved bindings, use the defaults".
    var gestureBindingsData: Data? {
        get { defaults.data(forKey: DefaultsKey.gestureBindings.rawValue) }
        set { setOrRemove(newValue, forKey: .gestureBindings) }
    }

    /// JSON-encoded `[ShortcutBinding]`; `nil` means "no saved keyboard shortcuts".
    var gestureShortcutBindingsData: Data? {
        get { defaults.data(forKey: DefaultsKey.gestureShortcutBindings.rawValue) }
        set { setOrRemove(newValue, forKey: .gestureShortcutBindings) }
    }

    private func setOrRemove(_ value: String?, forKey key: DefaultsKey) {
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    private func setOrRemove(_ value: Data?, forKey key: DefaultsKey) {
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
