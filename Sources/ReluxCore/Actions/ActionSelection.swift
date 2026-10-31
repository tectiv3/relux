/// Open flag and cursor of a panel's actions overlay.
///
/// All four panels share the same menu contract — Cmd+K resets the cursor to the first row and
/// flips the menu, Up/Down wrap at both ends, and an empty menu lets the key fall through — so
/// the bookkeeping lives here instead of once per view. Movement delegates to `ResultSelection`
/// so there is a single wrap-around implementation. A panel whose menu has no rows (invalid JWT,
/// no selected clip) simply cannot open.
public struct ActionSelection: Equatable, Sendable {
    public private(set) var isOpen: Bool
    public private(set) var index: Int

    public init(isOpen: Bool = false, index: Int = 0) {
        self.isOpen = isOpen
        self.index = index
    }

    /// Cmd+K. `isAvailable` false leaves the menu as it is: there is nothing to show.
    public mutating func toggle(isAvailable: Bool) {
        guard isAvailable else { return }
        index = 0
        isOpen.toggle()
    }

    public mutating func close() {
        isOpen = false
    }

    /// Previous row, wrapping before the first. Returns false on an empty menu so the caller can
    /// pass the key on instead of consuming it.
    @discardableResult
    public mutating func moveUp(count: Int) -> Bool {
        guard count > 0 else { return false }
        index = ResultSelection.retreated(index, count: count)
        return true
    }

    /// Next row, wrapping past the last: Down, and the search panel's Tab, both use it.
    @discardableResult
    public mutating func moveDown(count: Int) -> Bool {
        guard count > 0 else { return false }
        index = ResultSelection.advanced(index, count: count)
        return true
    }

    /// Row Return should run, or nil when the cursor sits outside the list.
    public func activationIndex(count: Int) -> Int? {
        guard index >= 0, index < count else { return nil }
        return index
    }
}
