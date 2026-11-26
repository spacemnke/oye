import SwiftUI
import AppKit
import OyeCore

/// Oye's own panel: your name on first run, then your people, inviting someone, and joining with a code.
struct HomeView: View {
    @ObservedObject var store: Store
    @State private var name = ""
    @State private var code = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("oye")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            if store.myName.isEmpty {
                welcome
            } else {
                people
                invite
                joining
            }
            if let notice = store.notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button("Quit Oye") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .padding(20)
        .background(Color.white)
    }

    private var statusLine: String {
        switch store.status {
        case .connecting: return "Connecting"
        case .online: return store.me?.name ?? "Online"
        case .offline(let why): return why
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should people call you?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            field("Your name", text: $name) { store.setName(name) }
            pill("Continue", filled: true) { store.setName(name) }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your people")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if store.people.isEmpty {
                Text("Nobody yet. Send someone an invite and they'll appear as a face in your menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.people) { person in
                            HStack(spacing: 10) {
                                FaceView(person: person, size: 28)
                                Text(person.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Button("Remove") { store.remove(person.id) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private var invite: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let code = store.inviteCode {
                Text(code)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    pill(copied ? "Copied" : "Copy invite", filled: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Invite.shareText(code: code), forType: .string)
                        copied = true
                    }
                    pill("New code", filled: false) {
                        copied = false
                        store.makeInvite()
                    }
                }
                Text("Good for a week. Anyone who opens it is linked with you.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            } else {
                pill("Invite someone", filled: true) { store.makeInvite() }
            }
        }
    }

    private var joining: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Got an invite?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 8) {
                field("Paste the code or link", text: $code, submit: join)
                pill("Join", filled: false, action: join)
                    .disabled(Invite.code(in: code) == nil)
            }
        }
    }

    private func join() {
        store.join(code)
        code = ""
    }

    private func field(_ prompt: String, text: Binding<String>, submit: @escaping () -> Void) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Theme.ink)
            .onSubmit(submit)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(Theme.soft))
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? Color.white : Theme.ink)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(filled ? Theme.ink : Theme.soft))
            .overlay(Capsule().stroke(filled ? Color.clear : Theme.line, lineWidth: 1))
    }
}
