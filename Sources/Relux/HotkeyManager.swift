import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRelux = Self("toggleRelux", default: .init(.space, modifiers: [.option]))
    static let clipboardHistory = Self("clipboardHistory", default: .init(.v, modifiers: [.option, .command]))
}
