import AppKit
import Foundation

@MainActor
final class SystemSettingsSearcher {
    struct SettingsPane: Sendable {
        let name: String
        let keywords: [String]
        let url: String
    }

    private static let urlBase = "x-apple.systempreferences:"

    /// macOS 13+ deep links
    static let panes: [SettingsPane] = [
        SettingsPane(
            name: "Wi-Fi",
            keywords: ["wifi", "wireless", "network"],
            url: urlBase + "com.apple.wifi-settings-extension"
        ),
        SettingsPane(
            name: "Bluetooth",
            keywords: ["bluetooth", "bt"],
            url: urlBase + "com.apple.BluetoothSettings"
        ),
        SettingsPane(
            name: "Network",
            keywords: ["network", "ethernet", "vpn", "dns"],
            url: urlBase + "com.apple.Network-Settings.extension"
        ),
        SettingsPane(
            name: "Sound",
            keywords: ["sound", "audio", "volume", "speaker", "microphone"],
            url: urlBase + "com.apple.Sound-Settings.extension"
        ),
        SettingsPane(
            name: "Displays",
            keywords: ["display", "monitor", "screen", "resolution", "brightness"],
            url: urlBase + "com.apple.Displays-Settings.extension"
        ),
        SettingsPane(
            name: "Keyboard",
            keywords: ["keyboard", "keys", "input", "typing", "shortcuts"],
            url: urlBase + "com.apple.Keyboard-Settings.extension"
        ),
        SettingsPane(
            name: "Trackpad",
            keywords: ["trackpad", "touchpad", "gesture"],
            url: urlBase + "com.apple.Trackpad-Settings.extension"
        ),
        SettingsPane(
            name: "Mouse",
            keywords: ["mouse", "cursor", "pointer"],
            url: urlBase + "com.apple.Mouse-Settings.extension"
        ),
        SettingsPane(
            name: "Printers & Scanners",
            keywords: ["printer", "scanner", "print"],
            url: urlBase + "com.apple.Print-Scan-Settings.extension"
        ),
        SettingsPane(
            name: "Battery",
            keywords: ["battery", "power", "energy", "charging"],
            url: urlBase + "com.apple.Battery-Settings.extension"
        ),
        SettingsPane(
            name: "Appearance",
            keywords: ["appearance", "theme", "dark", "light", "accent"],
            url: urlBase + "com.apple.Appearance-Settings.extension"
        ),
        SettingsPane(
            name: "Accessibility",
            keywords: ["accessibility", "voiceover", "zoom", "a11y"],
            url: urlBase + "com.apple.Accessibility-Settings.extension"
        ),
        SettingsPane(
            name: "Privacy & Security",
            keywords: ["privacy", "security", "permissions", "firewall"],
            url: urlBase + "com.apple.settings.PrivacySecurity.extension"
        ),
        SettingsPane(
            name: "General",
            keywords: ["general", "about", "software update", "storage", "airdrop", "login"],
            url: urlBase + "com.apple.systempreferences.GeneralSettings"
        ),
        SettingsPane(
            name: "Desktop & Dock",
            keywords: ["desktop", "dock", "stage manager", "wallpaper", "mission control"],
            url: urlBase + "com.apple.Desktop-Settings.extension"
        ),
        SettingsPane(
            name: "Notifications",
            keywords: ["notifications", "alerts", "banners", "focus"],
            url: urlBase + "com.apple.Notifications-Settings.extension"
        ),
        SettingsPane(
            name: "Focus",
            keywords: ["focus", "do not disturb", "dnd"],
            url: urlBase + "com.apple.Focus-Settings.extension"
        ),
        SettingsPane(
            name: "Screen Time",
            keywords: ["screen time", "usage", "limits"],
            url: urlBase + "com.apple.Screen-Time-Settings.extension"
        ),
        SettingsPane(
            name: "Lock Screen",
            keywords: ["lock screen", "screensaver", "screen saver", "password"],
            url: urlBase + "com.apple.Lock-Screen-Settings.extension"
        ),
        SettingsPane(
            name: "Users & Groups",
            keywords: ["users", "groups", "account", "login"],
            url: urlBase + "com.apple.Users-Groups-Settings.extension"
        ),
        SettingsPane(
            name: "Passwords",
            keywords: ["passwords", "keychain", "passkey"],
            url: urlBase + "com.apple.Passwords-Settings.extension"
        ),
        SettingsPane(
            name: "Internet Accounts",
            keywords: ["internet", "accounts", "icloud", "mail", "google"],
            url: urlBase + "com.apple.Internet-Accounts-Settings.extension"
        ),
        SettingsPane(
            name: "Wallet & Apple Pay",
            keywords: ["wallet", "apple pay", "payment"],
            url: urlBase + "com.apple.WalletSettingsExtension"
        ),
        SettingsPane(
            name: "Siri",
            keywords: ["siri", "assistant", "voice"],
            url: urlBase + "com.apple.Siri-Settings.extension"
        ),
        SettingsPane(
            name: "Sharing",
            keywords: ["sharing", "airdrop", "airplay", "remote"],
            url: urlBase + "com.apple.Sharing-Settings.extension"
        ),
        SettingsPane(
            name: "Time Machine",
            keywords: ["time machine", "backup"],
            url: urlBase + "com.apple.Time-Machine-Settings.extension"
        ),
        SettingsPane(
            name: "Startup Disk",
            keywords: ["startup", "boot", "disk"],
            url: urlBase + "com.apple.Startup-Disk-Settings.extension"
        ),
    ]

    func search(_ query: String, limit: Int = 5) -> [SearchItem] {
        guard !query.isEmpty else { return [] }
        let lowercasedQuery = query.lowercased()

        var scored: [(pane: SettingsPane, score: Double)] = []
        for pane in Self.panes {
            let name = pane.name.lowercased()
            if name == lowercasedQuery {
                scored.append((pane, 850))
            } else if name.hasPrefix(lowercasedQuery) {
                scored.append((pane, 750))
            } else if name.contains(lowercasedQuery) {
                scored.append((pane, 550))
            } else if pane.keywords.contains(where: { $0.hasPrefix(lowercasedQuery) }) {
                scored.append((pane, 700))
            } else if pane.keywords.contains(where: { $0.contains(lowercasedQuery) }) {
                scored.append((pane, 450))
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { item in
            SearchItem(
                id: "settings:\(item.pane.url)",
                title: item.pane.name,
                subtitle: "System Settings",
                icon: "gear",
                kind: .systemSettings,
                meta: ["url": item.pane.url],
                score: item.score
            )
        }
    }
}
