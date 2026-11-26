import AppKit
import SwiftUI
import Combine
import OyeCore

/// The menu bar: one face per person, plus Oye's own icon. Clicking a face opens its thread.
@MainActor
final class FaceBar: NSObject, NSPopoverDelegate {
    private let store: Store
    private var home: NSStatusItem?
    private var items: [UUID: NSStatusItem] = [:]
    private var popover: NSPopover?
    /// Whose thread is open, if any.
    private var openPerson: UUID?
    private var watching: Set<AnyCancellable> = []

    init(store: Store) {
        self.store = store
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Avatar.homeImage()
        item.button?.toolTip = "Oye"
        item.button?.setAccessibilityLabel("Oye")
        item.button?.target = self
        item.button?.action = #selector(homeClicked(_:))
        home = item
        // Any change to people, threads or the clock redraws the faces.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &watching)
        refresh()
    }

    private func refresh() {
        let people = store.people
        for (id, item) in items where !people.contains(where: { $0.id == id }) {
            NSStatusBar.system.removeStatusItem(item)
            items[id] = nil
        }
        for person in people {
            let item = items[person.id] ?? makeItem(for: person)
            let unread = store.unread(from: person.id)
            item.button?.image = Avatar.menuBarImage(for: person, here: store.isHere(person), unread: unread > 0 && openPerson != person.id)
            item.button?.toolTip = unread > 0 ? "\(person.name), \(unread) new" : person.name
            item.button?.setAccessibilityLabel(person.name)
        }
    }

    private func makeItem(for person: Person) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 26)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(faceClicked(_:))
        item.button?.identifier = NSUserInterfaceItemIdentifier(person.id.uuidString)
        items[person.id] = item
        return item
    }

    @objc private func homeClicked(_ sender: NSStatusBarButton) {
        showHome()
    }

    @objc private func faceClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if openPerson == id, popover?.isShown == true {
            close()
            return
        }
        show(ChatView(store: store, personID: id), from: sender, size: NSSize(width: 380, height: 480))
        openPerson = id
        store.markRead(id)
        refresh()
    }

    func showHome() {
        guard let button = home?.button else { return }
        if openPerson == nil, popover?.isShown == true {
            close()
            return
        }
        show(HomeView(store: store), from: button, size: NSSize(width: 340, height: 440))
        openPerson = nil
    }

    private func show<Content: View>(_ view: Content, from button: NSStatusBarButton, size: NSSize) {
        close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = size
        popover.contentViewController = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        // A menu bar app isn't frontmost by default, and the text field needs the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        self.popover = popover
    }

    private func close() {
        popover?.performClose(nil)
        popover = nil
        openPerson = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            guard let closed = notification.object as? NSPopover, closed === self.popover else { return }
            self.popover = nil
            self.openPerson = nil
            self.refresh()
        }
    }
}
