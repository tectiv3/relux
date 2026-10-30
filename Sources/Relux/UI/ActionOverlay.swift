import ReluxCore
import SwiftUI

/// An actions row bound to the behaviour it runs.
struct Action {
    let descriptor: ActionDescriptor
    let handler: () -> Void

    init(_ descriptor: ActionDescriptor, handler: @escaping () -> Void) {
        self.descriptor = descriptor
        self.handler = handler
    }
}

/// The actions card shared by the four panels.
///
/// Header content, width and placement stay per-panel (they genuinely differ: the search overlay
/// heads its menu with the row's own icon, the JWT menu has no header, and widths run 220...300),
/// but the glass, hairlines, row rendering, highlight and tap-to-run behaviour are one code path.
struct ActionOverlay<Header: View>: View {
    enum Placement {
        /// Card only, for a container that already aligns it bottom-trailing (the search overlay's
        /// results `ZStack`).
        case inline
        /// Aligned bottom-trailing in the panel with the shared 8pt inset.
        case bottomTrailing
    }

    let actions: [Action]
    let selectedIndex: Int
    let width: CGFloat
    let placement: Placement
    let onSelect: (Int) -> Void
    private let header: () -> Header

    init(
        actions: [Action],
        selectedIndex: Int,
        width: CGFloat,
        placement: Placement = .bottomTrailing,
        onSelect: @escaping (Int) -> Void,
        @ViewBuilder header: @escaping () -> Header
    ) {
        self.actions = actions
        self.selectedIndex = selectedIndex
        self.width = width
        self.placement = placement
        self.onSelect = onSelect
        self.header = header
    }

    var body: some View {
        switch placement {
        case .inline:
            card
        case .bottomTrailing:
            card
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header()

            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                row(action.descriptor, isSelected: index == selectedIndex)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard action.descriptor.isEnabled else { return }
                        onSelect(index)
                    }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: width)
    }

    private func row(_ descriptor: ActionDescriptor, isSelected: Bool) -> some View {
        // A disabled row never takes the highlight, so Enter and the cursor can never look armed.
        let isHighlighted = isSelected && descriptor.isEnabled
        return HStack(spacing: 10) {
            Image(systemName: descriptor.icon)
                .foregroundColor(isHighlighted ? .white.opacity(0.8) : .secondary)
                .font(.system(size: 13))
                .frame(width: 20)

            Text(descriptor.label)
                .font(.system(size: 13))

            Spacer()

            if let shortcut = descriptor.shortcut {
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundColor(isHighlighted ? .white.opacity(0.6) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(isHighlighted ? .white : .primary)
    }
}

/// The bordered key cap plus label every panel's footer uses.
struct KeyboardHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                )
            Text(label)
        }
    }
}
