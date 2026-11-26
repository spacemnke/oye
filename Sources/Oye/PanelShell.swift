import SwiftUI

/// The soft rounded panel from the designs, with room around it for its shadow.
struct PanelShell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.panelPadding)
            .frame(width: Theme.panelWidth)
            .background(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).fill(Theme.soft))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Theme.ink.opacity(0.10), radius: 40, x: 0, y: 30)
            .padding(.horizontal, Theme.shadowRoom)
            .padding(.bottom, Theme.shadowRoom + 30)
            .padding(.top, 4)
            .environment(\.colorScheme, .light)
    }
}
