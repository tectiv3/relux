import AppKit
import Foundation

@MainActor
final class SystemSettingsSearcher {
    struct SettingsPane: Sendable {
        let name: String
        let keywords: [String]
        let url: String
    }

    /// macOS 13+ deep links
    static let panes: [SettingsPane] = [
        SettingsPane(name: "Wi-Fi", keywords: ["wifi", "wireless", "network"], url: "x-apple.systempreferences:com.apple.wifi-settings-extension"),
        SettingsPane(name: "Bluetooth", keywords: ["bluetooth", "bt"], url: "x-apple.systempreferences:com.apple.BluetoothSettings"),
        SettingsPane(name: "Network", keywords: ["network", "ethernet", "vpn", "dns"], url: "x-apple.systempreferences:com.apple.Network-Settings.extension"),
        SettingsPane(name: "Sound", keywords: ["sound", "audio", "volume", "speaker", "microphone"], url: "x-apple.systempreferences:com.apple.Sound-Settings.extension"),
        SettingsPane(name: "Displays", keywords: ["display", "monitor", "screen", "resolution", "brightness"], url: "x-apple.systempreferences:com.apple.Displays-Settings.extension"),
        SettingsPane(name: "Keyboard", keywords: ["keyboard", "keys", "input", "typing", "shortcuts"], url: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"),
        SettingsPane(name: "Trackpad", keywords: ["trackpad", "touchpad", "gesture"], url: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"),
        SettingsPane(name: "Mouse", keywords: ["mouse", "cursor", "pointer"], url: "x-apple.systempreferences:com.apple.Mouse-Settings.extension"),
        SettingsPane(name: "Printers & Scanners", keywords: ["printer", "scanner", "print"], url: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension"),
        SettingsPane(name: "Battery", keywords: ["battery", "power", "energy", "charging"], url: "x-apple.systempreferences:com.apple.Battery-Settings.extension"),
        SettingsPane(name: "Appearance", keywords: ["appearance", "theme", "dark", "light", "accent"], url: "x-apple.systempreferences:com.apple.Appearance-Settings.extension"),
        SettingsPane(name: "Accessibility", keywords: ["accessibility", "voiceover", "zoom", "a11y"], url: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"),
        SettingsPane(name: "Privacy & Security", keywords: ["privacy", "security", "permissions", "firewall"], url: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"),
        SettingsPane(name: "General", keywords: ["general", "about", "software update", "storage", "airdrop", "login"], url: "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings"),
        SettingsPane(name: "Desktop & Dock", keywords: ["desktop", "dock", "stage manager", "wallpaper", "mission control"], url: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"),
        SettingsPane(name: "Notifications", keywords: ["notifications", "alerts", "banners", "focus"], url: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
        SettingsPane(name: "Focus", keywords: ["focus", "do not disturb", "dnd"], url: "x-apple.systempreferences:com.apple.Focus-Settings.extension"),
        SettingsPane(name: "Screen Time", keywords: ["screen time", "usage", "limits"], url: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension"),
        SettingsPane(name: "Lock Screen", keywords: ["lock screen", "screensaver", "screen saver", "password"], url: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"),
        SettingsPane(name: "Users & Groups", keywords: ["users", "groups", "account", "login"], url: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"),
        SettingsPane(name: "Passwords", keywords: ["passwords", "keychain", "passkey"], url: "x-apple.systempreferences:com.apple.Passwords-Settings.extension"),
        SettingsPane(name: "Internet Accounts", keywords: ["internet", "accounts", "icloud", "mail", "google"], url: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension"),
        SettingsPane(name: "Wallet & Apple Pay", keywords: ["wallet", "apple pay", "payment"], url: "x-apple.systempreferences:com.apple.WalletSettingsExtension"),
        SettingsPane(name: "Siri", keywords: ["siri", "assistant", "voice"], url: "x-apple.systempreferences:com.apple.Siri-Settings.extension"),
        SettingsPane(name: "Sharing", keywords: ["sharing", "airdrop", "airplay", "remote"], url: "x-apple.systempreferences:com.apple.Sharing-Settings.extension"),
        SettingsPane(name: "Time Machine", keywords: ["time machine", "backup"], url: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"),
        SettingsPane(name: "Startup Disk", keywords: ["startup", "boot", "disk"], url: "x-apple.systempreferences:com.apple.Startup-Disk-Settings.extension"),
    ]

    func search(_ query: String, limit: Int = 5) -> [SearchItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()

        var scored: [(pane: SettingsPane, score: Int)] = []
        for pane in Self.panes {
            let name = pane.name.lowercased()
            if name == q {
                scored.append((pane, 100))
            } else if name.hasPrefix(q) {
                scored.append((pane, 80))
            } else if name.contains(q) {
                scored.append((pane, 60))
            } else if pane.keywords.contains(where: { $0.hasPrefix(q) }) {
                scored.append((pane, 70))
            } else if pane.keywords.contains(where: { $0.contains(q) }) {
                scored.append((pane, 50))
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
                meta: ["url": item.pane.url]
            )
        }
    }
}
