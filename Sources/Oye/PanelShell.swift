import SwiftUI

/// The soft rounded panel from the designs, with room around it for its shadow.
struct PanelShell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.panelPadding)
            .frame(width: Theme.panelWidth)
            // The shadow belongs to the panel's shape alone, not to everything inside it.
            .background(
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .fill(Theme.soft)
                    .shadow(color: Theme.ink.opacity(0.10), radius: 40, x: 0, y: 30)
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .padding(.horizontal, Theme.shadowRoom)
            .padding(.bottom, Theme.shadowRoom + 30)
            .padding(.top, 4)
            .environment(\.colorScheme, .light)
    }
}

/// Sizes itself to its content up to a cap, and no taller. The thread uses it to hug its bubbles
/// until there are too many, then scroll.
struct CapHeight: Layout {
    var cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
