import Foundation

/// The name an application row shows and that the ranker scores.
///
/// Spotlight reports a bundle's `kMDItemDisplayName` with its extension
/// (`"Microsoft Remote Desktop.app"`), while the other name sources derive the name from the
/// path and strip it. Rows therefore disagreed depending on which source found the app, and the
/// ranker scored a 4-character-longer string than the user sees — which shifts the
/// `min(name.count, 60)` length penalty and puts the exact-name tier out of reach for every app.
/// Normalising at the single place the name is stored keeps display and scoring identical.
public enum AppDisplayName {
    private static let bundleExtension = ".app"

    /// `"Microsoft Remote Desktop.app"` -> `"Microsoft Remote Desktop"`. Names without the
    /// extension pass through unchanged.
    public static func from(bundleName name: String) -> String {
        guard name.count > bundleExtension.count,
              name.lowercased().hasSuffix(bundleExtension)
        else { return name }
        return String(name.dropLast(bundleExtension.count))
    }
}
