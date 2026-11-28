import AppKit
import OyeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private var faces: FaceBar?
    private var live: LiveCheck?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Oye lives in the menu bar; no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        Theme.registerFonts()
        // CI opens the packaged app once to prove it starts, then quits.
        if ProcessInfo.processInfo.environment["OYE_SMOKE_TEST"] != nil {
            // Say whether the fonts were found, so the package check can tell.
            print("Oye started, fonts " + (Resources.folder("Fonts") == nil ? "missing" : "found"))
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            return
        }
        let faces = FaceBar(store: store)
        faces.install()
        self.faces = faces
        store.start()
        // Screenshots (OYE_SHOTS=folder, with OYE_DEMO): draw the panels to PNGs and leave a thread open.
        if let folder = ProcessInfo.processInfo.environment["OYE_SHOTS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.takeShots(into: folder) }
            return
        }
        // The live check (OYE_LIVE=ana or ben): this copy plays one of two people, for real.
        let env = ProcessInfo.processInfo.environment
        if let role = env["OYE_LIVE"].flatMap(LiveCheck.Role.init(rawValue:)), let folder = env["OYE_LIVE_DIR"] {
            let check = LiveCheck(store: store, role: role, folder: folder) { [weak self] id in self?.faces?.showChat(id) }
            live = check
            check.run()
            return
        }
        // First run: nobody knows your name yet, so open the Oye panel to ask.
        if store.myName.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.faces?.showHome() }
        }
    }

    private func takeShots(into folder: String) {
        func note(_ text: String) { FileHandle.standardError.write(Data(("shots: " + text + "\n").utf8)) }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The designs open Ines's thread.
        guard let open = store.people.first(where: { $0.name.hasPrefix("Ines") }) ?? store.people.first else { return }
        // The real panel first, for the screen capture; the drawn copies follow.
        note("opening the panel")
        faces?.showChat(open.id)
        note("panel open")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            note("drawing faces")
            Shots.saveStrip(store: self.store, open: open.id, to: dir.appendingPathComponent("faces.png"))
            note("drawing chat")
            Shots.save(ChatView(store: self.store, personID: open.id), to: dir.appendingPathComponent("chat.png"))
            // The recording flow, in each of its states.
            let now = Date()
            for (kind, name) in [(Capture.Kind.voice, "voice"), (.video, "video"), (.screen, "screen")] {
                note("drawing " + name)
                self.store.capture.start(kind, for: open.id, now: now.addingTimeInterval(-7))
                self.store.captureNow = now
                if kind != .screen {
                    Shots.save(ChatView(store: self.store, personID: open.id), to: dir.appendingPathComponent("recording-\(name).png"))
                }
                self.store.capture.stop(now: now)
                Shots.save(ChatView(store: self.store, personID: open.id), to: dir.appendingPathComponent("review-\(name).png"))
                self.store.capture.clear()
            }
            // More people than fit in the menu bar: the row with "+N", and the list behind it.
            note("drawing the crowd")
            func extra(_ n: Int, _ name: String, here: Bool) -> Person {
                Person(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 100 + n))!, name: name, lastSeen: here ? now : nil)
            }
            let crowd = self.store.people + [
                extra(1, "Noor Haddad", here: true), extra(2, "Sam Okafor", here: false), extra(3, "Yuki Tanaka", here: true),
                extra(4, "Elena Rossi", here: false), extra(5, "Dev Patel", here: false), extra(6, "Carla Mendes", here: true)
            ]
            let split = Lineup.split(crowd, most: FaceStrip.most) { person in
                Lineup.Standing(here: self.store.isHere(person), last: self.store.conversations.thread(with: person.id).last?.createdAt)
            }
            Shots.saveStrip(FaceStrip(people: split.shown, open: nil, more: split.more.count), store: self.store,
                            to: dir.appendingPathComponent("faces-more.png"))
            Shots.save(MoreView(store: self.store, people: split.more, open: { _ in }), to: dir.appendingPathComponent("more.png"))
            note("drawing home")
            Shots.save(HomeView(store: self.store), to: dir.appendingPathComponent("home.png"))
            note("done")
        }
    }

    /// Someone opened an invite link (oye://join/CODE).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let code = Invite.code(in: url.absoluteString) else { continue }
            store.join(code)
            faces?.showHome()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ProcessInfo.processInfo.environment["OYE_SMOKE_TEST"] != nil { return .terminateNow }
        // Tell people you've gone, so you show as away at once. Two seconds at most.
        Task {
            await store.signOff(timeout: 2)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
