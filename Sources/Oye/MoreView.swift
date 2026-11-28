import SwiftUI
import OyeCore

/// The people who don't fit in the menu bar, behind "+N". Click one to open their thread.
struct MoreView: View {
    @ObservedObject var store: Store
    let people: [Person]
    let open: (UUID) -> Void

    /// More rows than this and the list scrolls.
    private static let rowsBeforeScrolling = 8
    private static let rowHeight: CGFloat = 44

    var body: some View {
        PanelShell {
            VStack(alignment: .leading, spacing: 10) {
                Text("More people")
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(Theme.ink)
                if people.count > Self.rowsBeforeScrolling {
                    ScrollView { rows }
                        .scrollIndicators(.never)
                        .frame(height: CGFloat(Self.rowsBeforeScrolling) * Self.rowHeight)
                } else {
                    rows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(people) { person in
                Button {
                    open(person.id)
                } label: {
                    HStack(spacing: 10) {
                        FaceView(person: person, photo: store.photo(for: person), size: 32)
                            .opacity(store.isHere(person) ? 1 : 0.45)
                        Text(person.name)
                            .font(Theme.font(14))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        if store.unread(from: person.id) > 0 {
                            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                        }
                        Text(store.isHere(person) ? "Here now" : "Away")
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(height: Self.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
