import AppKit
import OyeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private var faces: FaceBar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Oye lives in the menu bar; no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        // CI opens the packaged app once to prove it starts, then quits.
        if ProcessInfo.processInfo.environment["OYE_SMOKE_TEST"] != nil {
            print("Oye started")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            return
        }
        let faces = FaceBar(store: store)
        faces.install()
        self.faces = faces
        store.start()
        // First run: nobody knows your name yet, so open the Oye panel to ask.
        if store.myName.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.faces?.showHome() }
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
