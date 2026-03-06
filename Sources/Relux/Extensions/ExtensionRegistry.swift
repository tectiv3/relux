import Foundation

@MainActor @Observable
final class ExtensionRegistry {
    struct Extension: Identifiable, Sendable {
        let id: String
        let name: String
        let icon: String
        var isEnabled: Bool
        nonisolated(unsafe) var availabilityCheck: (@MainActor () -> Bool)?
    }

    private(set) var extensions: [Extension] = []

    func isEnabled(_ id: String) -> Bool {
        extensions.first(where: { $0.id == id })?.isEnabled ?? false
    }

    func isReady(_ id: String) -> Bool {
        guard let ext = extensions.first(where: { $0.id == id }) else { return false }
        guard ext.isEnabled else { return false }
        return ext.availabilityCheck?() ?? true
    }

    func setEnabled(_ id: String, enabled: Bool) {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }
        extensions[index].isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "extension.\(id).enabled")
    }

    func register(
        id: String, name: String, icon: String, defaultEnabled: Bool,
        availabilityCheck: (@MainActor () -> Bool)? = nil
    ) {
        let stored = UserDefaults.standard.object(forKey: "extension.\(id).enabled") as? Bool
        let isEnabled = stored ?? defaultEnabled
        extensions.append(Extension(
            id: id, name: name, icon: icon,
            isEnabled: isEnabled, availabilityCheck: availabilityCheck
        ))
    }
}
