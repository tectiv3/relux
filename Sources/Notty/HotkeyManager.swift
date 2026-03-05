import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleNotty = Self("toggleNotty", default: .init(.space, modifiers: [.option]))
    static let clipboardHistory = Self("clipboardHistory", default: .init(.v, modifiers: [.option, .command]))
}
