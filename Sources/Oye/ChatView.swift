import SwiftUI
import OyeCore

/// The panel under a face, as designed: who they are, the thread, a field to text them, buttons for
/// a voice note and a file, and hold to talk.
struct ChatView: View {
    @ObservedObject var store: Store
    let personID: UUID
    @State private var draft = ""
    @State private var hint: String?
    @FocusState private var typing: Bool

    private var person: Person? { store.person(personID) }
    private var thread: [Message] { store.conversations.thread(with: personID) }
    /// "Ines Marin" is texted as "Ines".
    private var firstName: String { person?.name.split(separator: " ").first.map(String.init) ?? "them" }

    var body: some View {
        PanelShell {
            VStack(alignment: .leading, spacing: 16) {
                header
                messages
                composer
            }
        }
        .onAppear { typing = true }
        .onChange(of: thread.count) { _, _ in store.markRead(personID) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let person {
                FaceView(person: person, photo: store.photo(for: person), size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(Theme.font(18, .semibold))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.isHere(person) ? Theme.here : Theme.muted.opacity(0.5))
                            .frame(width: 8, height: 8)
                        Text(store.isHere(person) ? "Here now" : "Away")
                            .font(Theme.font(14))
                            .foregroundStyle(Theme.muted)
                    }
                }
            } else {
                Text("No longer in your menu bar")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
    }

    /// The thread hugs its bubbles until it's taller than this, then scrolls.
    private static let tallest: CGFloat = 340

    private var bubbles: some View {
        VStack(spacing: 8) {
            if thread.isEmpty {
                Text("Say oye.")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(thread) { message in
                Bubble(message: message, mine: message.sender != personID)
                    .id(message.id)
            }
        }
    }

    private var messages: some View {
        ViewThatFits(in: .vertical) {
            bubbles
            ScrollViewReader { proxy in
                ScrollView {
                    bubbles
                }
                .frame(height: Self.tallest)
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: thread.count) { _, _ in scrollToEnd(proxy) }
            }
        }
        .frame(maxHeight: Self.tallest)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = thread.last else { return }
        DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("", text: $draft, prompt: Text("Text \(firstName)").foregroundColor(Theme.muted))
                    .textFieldStyle(.plain)
                    .font(Theme.font(16))
                    .foregroundStyle(Theme.ink)
                    .focused($typing)
                    .onSubmit(send)
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                round(.mic, label: "Record a voice note") { hint = "Voice notes arrive in the next build." }
                round(.clip, label: "Send a file") { hint = "File drops arrive in the next build." }
            }
            Button {
                hint = "Hold to talk arrives in the next build."
            } label: {
                HStack(spacing: 8) {
                    Icon(kind: .wave)
                    Text("Hold to talk")
                        .font(Theme.font(16, .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Capsule().fill(Theme.ink))
            }
            .buttonStyle(.plain)
            if let hint {
                Text(hint)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 6)
            }
        }
    }

    private func round(_ kind: Icon.Kind, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(kind: kind)
                .foregroundStyle(Theme.ink)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.white))
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func send() {
        guard person != nil, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.send(draft, to: personID)
        draft = ""
        typing = true
    }
}

/// One message. Yours sit on the right in indigo; theirs on the left in white, with one squared-off
/// corner pointing at whoever sent it.
private struct Bubble: View {
    let message: Message
    let mine: Bool

    var body: some View {
        HStack(spacing: 0) {
            if mine { Spacer(minLength: 0) }
            // Bubbles hug their words up to the design's width, then wrap.
            content.frame(maxWidth: 264, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .text:
            Text(message.body)
                .font(Theme.font(14))
                .lineSpacing(2)
                .foregroundStyle(mine ? Color.white : Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(shape.fill(mine ? Theme.accent : Color.white))
                .overlay(shape.stroke(mine ? Color.clear : Theme.line, lineWidth: 1))
        case .file:
            HStack(spacing: 10) {
                Icon(kind: .file).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.fileName ?? "File")
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(Self.size(message.bytes))
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
        case .voice:
            HStack(spacing: 10) {
                Icon(kind: .play)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.ink))
                HStack(spacing: 3) {
                    ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, tall in
                        RoundedRectangle(cornerRadius: 2).fill(Theme.ink).frame(width: 3, height: tall)
                    }
                }
                Text(Self.length(message.seconds))
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(shape.fill(Color.white))
            .overlay(shape.stroke(Theme.line, lineWidth: 1))
        }
    }

    /// 16-point corners, 4 on the corner nearest the sender.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: mine ? 16 : 4,
                               bottomTrailingRadius: mine ? 4 : 16, topTrailingRadius: 16, style: .continuous)
    }

    private static let bars: [CGFloat] = [6, 12, 18, 9, 14, 20, 11, 7, 15, 10, 17, 8, 13, 6]

    private static func size(_ bytes: Int?) -> String {
        guard let bytes else { return "" }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        return "\(max(1, bytes / 1000)) KB"
    }

    private static func length(_ seconds: Double?) -> String {
        let total = Int((seconds ?? 0).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
