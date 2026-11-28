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
        PanelShell {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("oye")
                    .font(Theme.font(26, .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(statusLine)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.muted)
            }
            if store.myName.isEmpty {
                welcome
            } else {
                people
                invite
                joining
                anyone
                Toggle(isOn: $store.doNotDisturb) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Do not disturb")
                            .font(Theme.font(14, .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Hold to talk won't play out loud on this Mac.")
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.ink)
            }
            if let notice = store.notice {
                Text(notice)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.muted)
            }
            Button("Quit Oye") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(Theme.muted)
        }
        }
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
                .font(Theme.font(16, .semibold))
                .foregroundStyle(Theme.ink)
            field("Your name", text: $name) { store.setName(name) }
            pill("Continue", filled: true) { store.setName(name) }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your people")
                .font(Theme.font(14, .semibold))
                .foregroundStyle(Theme.ink)
            if store.people.isEmpty {
                Text("Nobody yet. Send someone an invite and they'll appear as a face in your menu bar.")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach(store.people) { person in
                            HStack(spacing: 10) {
                                FaceView(person: person, photo: store.photo(for: person), size: 32)
                                Text(person.name)
                                    .font(Theme.font(14))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Button("Remove") { store.remove(person.id) }
                                    .buttonStyle(.plain)
                                    .font(Theme.font(13))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
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
                        NSPasteboard.general.setString(Invite.shareText(code: code, from: store.myName), forType: .string)
                        copied = true
                    }
                    pill("New code", filled: false) {
                        copied = false
                        store.makeInvite()
                    }
                }
                Text("A link that works even if they don't have Oye yet. Good for a week; anyone who uses it is linked with you.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                pill("Invite someone", filled: true) { store.makeInvite() }
            }
        }
    }

    /// A file for someone who isn't one of your people: it becomes a link.
    private var anyone: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send a file to anyone")
                .font(Theme.font(14, .semibold))
                .foregroundStyle(Theme.ink)
            Text("Drop a file on Oye's icon in the menu bar, or choose one. You get a link: anyone who has it can download the file for 3 days.")
                .font(Theme.font(13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(store.transfers.filter { $0.to == nil }) { transfer in
                Text("Uploading \(transfer.name) · \(Labels.percent(transfer.fraction))")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(store.links, id: \.self) { link in
                Text(link)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                pill("Choose a file", filled: false) { store.chooseFilesToShare() }
                if !store.links.isEmpty {
                    Text(store.links.count == 1 ? "Link copied" : "Links copied")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var joining: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Got an invite?")
                .font(Theme.font(14, .semibold))
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
            .focusEffectDisabled()
            .font(Theme.font(15))
            .foregroundStyle(Theme.ink)
            .onSubmit(submit)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Theme.font(14, .semibold))
            .foregroundStyle(filled ? Color.white : Theme.ink)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Capsule().fill(filled ? Theme.ink : Color.white))
            .overlay(Capsule().stroke(filled ? Color.clear : Theme.line, lineWidth: 1))
    }
}
