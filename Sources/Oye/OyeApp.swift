import SwiftUI

@main
struct OyeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Everything lives in the menu bar; AppDelegate owns the faces and their panels.
        Settings {
            Text("Oye lives in your menu bar. Click the Oye icon there for invites and settings.")
                .padding(20)
                .frame(width: 360, alignment: .leading)
        }
    }
}
