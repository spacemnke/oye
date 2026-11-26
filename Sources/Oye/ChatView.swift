import SwiftUI
import OyeCore

/// The thread under a face: who they are, what you've said to each other, and a field to say more.
struct ChatView: View {
    @ObservedObject var store: Store
    let personID: UUID
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var person: Person? { store.person(personID) }
    private var thread: [Message] { store.conversations.thread(with: personID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            messages
            composer
        }
        .background(Theme.soft)
        .onAppear { typing = true }
        .onChange(of: thread.count) { _, _ in store.markRead(personID) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let person {
                FaceView(person: person, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.isHere(person) ? Theme.here : Theme.muted.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(store.isHere(person) ? "Here now" : "Away")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                }
            } else {
                Text("No longer in your menu bar")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(16)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if thread.isEmpty {
                        Text("Say oye.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 40)
                    }
                    ForEach(thread) { message in
                        Bubble(message: message, mine: message.sender != personID)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: thread.count) { _, _ in scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = thread.last else { return }
        DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Text \(person?.name ?? "them")", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .focused($typing)
                .onSubmit(send)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            Button("Send", action: send)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(canSend ? Theme.ink : Theme.muted.opacity(0.4)))
                .disabled(!canSend)
        }
        .padding(14)
    }

    private var canSend: Bool {
        person != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        store.send(draft, to: personID)
        draft = ""
        typing = true
    }
}

/// One message. Yours sit on the right in indigo; theirs on the left in white.
private struct Bubble: View {
    let message: Message
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 50) }
            Text(message.body)
                .font(.system(size: 14))
                .foregroundStyle(mine ? Color.white : Theme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(mine ? Theme.accent : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(mine ? Color.clear : Theme.line, lineWidth: 1))
            if !mine { Spacer(minLength: 50) }
        }
    }
}
