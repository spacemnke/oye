import AppKit
import SwiftUI
import Combine
import OyeCore

/// The menu bar: the row of faces (one item, so they can overlap as designed) and Oye's own icon.
/// Clicking a face opens its panel underneath.
@MainActor
final class FaceBar: NSObject, NSWindowDelegate {
    private let store: Store
    private var home: NSStatusItem?
    private var strip: NSStatusItem?
    private var panel: FloatingPanel?
    private var sizeWatch: NSKeyValueObservation?
    private var outsideClicks: Any?
    private var keys: Any?
    /// Whose panel is open. Nil with a panel showing means Oye's own.
    private var openPerson: UUID?
    /// The panel showing is the list behind "+N".
    private var moreOpen = false
    /// The point the open panel hangs from: the middle of its face, at the bottom of the menu bar.
    private var anchor = NSPoint.zero
    private var watching: Set<AnyCancellable> = []

    init(store: Store) {
        self.store = store
    }

    func install() {
        // Oye's icon is made first so it sits to the right of the faces.
        let home = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        home.button?.image = Avatar.homeImage()
        home.button?.toolTip = "Oye"
        home.button?.setAccessibilityLabel("Oye")
        home.button?.target = self
        home.button?.action = #selector(homeClicked(_:))
        self.home = home

        let strip = NSStatusBar.system.statusItem(withLength: 0)
        strip.button?.imagePosition = .imageOnly
        strip.button?.target = self
        strip.button?.action = #selector(stripClicked(_:))
        strip.button?.setAccessibilityLabel("Your people")
        self.strip = strip
        // Files dragged onto the row are sent to whoever's face they land on.
        if let button = strip.button {
            let catcher = DropCatcher(frame: button.bounds)
            catcher.autoresizingMask = [.width, .height]
            catcher.dropped = { [weak self] urls, x in self?.dropped(urls, at: x) }
            button.addSubview(catcher)
        }

        // Any change to people, threads or the clock redraws the faces.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &watching)
        refresh()
    }

    /// Who has a face in the menu bar right now, and who is behind "+N". `pin` always gets a face.
    private func lineup(pinning pin: UUID?) -> (strip: FaceStrip, more: [Person]) {
        let store = self.store
        let split = Lineup.split(store.people, most: FaceStrip.most) { person in
            Lineup.Standing(
                pinned: person.id == pin || store.talkingTo == person.id || store.hearing == person.id,
                unread: store.unread(from: person.id) > 0,
                here: store.isHere(person),
                last: store.conversations.thread(with: person.id).last?.createdAt
            )
        }
        let strip = FaceStrip(people: split.shown, open: panel == nil ? nil : openPerson, more: split.more.count,
                              moreUnread: split.more.contains { store.unread(from: $0.id) > 0 })
        return (strip, split.more)
    }

    private var faces: FaceStrip { lineup(pinning: panel == nil ? nil : openPerson).strip }

    private func refresh() {
        guard let strip else { return }
        followScreenRecording()
        let faces = self.faces
        let store = self.store
        strip.length = faces.width
        strip.isVisible = !faces.people.isEmpty
        strip.button?.image = faces.image(
            photo: { store.photo(for: $0) },
            here: { store.isHere($0) },
            unread: { store.unread(from: $0.id) > 0 },
            live: { store.talkingTo == $0.id || store.hearing == $0.id }
        )
        let waiting = faces.people.filter { store.unread(from: $0.id) > 0 }.map(\.name)
        strip.button?.toolTip = waiting.isEmpty ? "Your people" : "New from " + waiting.joined(separator: ", ")
    }

    // MARK: Screen recording

    private var screenRecording = false

    /// The panel gets out of the way while the screen records, and Oye's icon becomes the stop
    /// button with the time. Stopping brings the panel back to look at the recording.
    private func followScreenRecording() {
        let now = store.capture.recording == .screen
        if now {
            if !screenRecording {
                screenRecording = true
                if panel != nil { close() }
                home?.button?.image = Avatar.stopImage()
                home?.button?.imagePosition = .imageLeading
                home?.length = NSStatusItem.variableLength
                home?.button?.toolTip = "Stop recording"
            }
            home?.button?.title = " " + Labels.time(store.capture.elapsed(now: store.captureNow))
        } else if screenRecording {
            screenRecording = false
            home?.button?.image = Avatar.homeImage()
            home?.button?.title = ""
            home?.button?.imagePosition = .imageOnly
            home?.length = NSStatusItem.squareLength
            home?.button?.toolTip = "Oye"
            if store.capture.reviewing == .screen, let id = store.capture.target, panel == nil {
                DispatchQueue.main.async { [weak self] in self?.showChat(id) }
            }
        }
    }

    private func dropped(_ urls: [URL], at x: CGFloat) {
        let faces = self.faces
        // Dropped on "+N": there's no one face to send to, so show who's there.
        if faces.isMore(at: x) {
            if !moreOpen { showMore() }
            return
        }
        guard let person = faces.person(at: x) else { return }
        store.sendFiles(urls, to: person.id)
        showChat(person.id)
    }

    // MARK: Clicks

    @objc private func homeClicked(_ sender: NSStatusBarButton) {
        if store.capture.recording == .screen {
            store.stopRecording()
            return
        }
        showHome()
    }

    @objc private func stripClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let x = sender.convert(event.locationInWindow, from: nil).x
        let faces = self.faces
        if faces.isMore(at: x) {
            showMore()
            return
        }
        guard let person = faces.person(at: x) else { return }
        if panel != nil, openPerson == person.id {
            close()
        } else {
            showChat(person.id)
        }
    }

    /// Opens someone's panel, as if their face had been clicked.
    func showChat(_ id: UUID) {
        // Someone from behind "+N" takes a place in the row while their panel is open.
        guard let button = strip?.button,
              let slot = lineup(pinning: id).strip.frames.first(where: { $0.person.id == id }) else { return }
        show(ChatView(store: store, personID: id), under: button, at: slot.rect.midX)
        openPerson = id
        store.markRead(id)
        refresh()
    }

    /// The list behind "+N". Clicking "+N" again closes it.
    func showMore() {
        if panel != nil, moreOpen {
            close()
            return
        }
        let lineup = self.lineup(pinning: nil)
        guard let button = strip?.button, let chip = lineup.strip.chip else { return }
        let view = MoreView(store: store, people: lineup.more) { [weak self] id in self?.showChat(id) }
        show(view, under: button, at: chip.midX)
        openPerson = nil
        moreOpen = true
        refresh()
    }

    func showHome() {
        guard let button = home?.button else { return }
        if panel != nil, openPerson == nil, !moreOpen {
            close()
            return
        }
        show(HomeView(store: store), under: button, at: button.bounds.midX)
        openPerson = nil
        refresh()
    }

    // MARK: The panel

    private func show<Content: View>(_ view: Content, under button: NSStatusBarButton, at x: CGFloat) {
        close()
        guard let window = button.window else { return }
        let inWindow = button.convert(NSPoint(x: x, y: button.bounds.minY), to: nil)
        anchor = window.convertPoint(toScreen: inWindow)
        anchor.y = window.frame.minY

        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let panel = FloatingPanel(contentViewController: hosting)
        panel.delegate = self
        self.panel = panel
        place()
        // The panel grows and shrinks with its thread; keep it hanging from the same point.
        sizeWatch = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.place() }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // A click anywhere else, or Escape, closes it.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.close() }
            return nil
        }
    }

    /// Hangs the panel from its anchor: centred under the face, just below the menu bar, on screen.
    private func place() {
        guard let panel, let content = panel.contentViewController else { return }
        var size = content.preferredContentSize
        if size.width < 1 || size.height < 1 { size = content.view.fittingSize }
        var x = anchor.x - size.width / 2
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            // The shadow's room can hang off the edge; the panel itself can't.
            let room = Theme.shadowRoom - 8
            x = min(max(x, screen.visibleFrame.minX - room), screen.visibleFrame.maxX - size.width + room)
        }
        panel.setFrame(NSRect(x: x, y: anchor.y - 10 - size.height, width: size.width, height: size.height), display: true)
    }

    private func close() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let keys { NSEvent.removeMonitor(keys) }
        outsideClicks = nil
        keys = nil
        sizeWatch = nil
        guard let panel else { return }
        self.panel = nil
        openPerson = nil
        moreOpen = false
        panel.delegate = nil
        panel.orderOut(nil)
        refresh()
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        // Clicked into another app or window.
        Task { @MainActor in
            if ProcessInfo.processInfo.environment["OYE_SHOTS"] == nil { self.close() }
        }
    }
}

/// A borderless window that can still take typing. The panel's own shape and shadow are drawn in SwiftUI.
final class FloatingPanel: NSPanel {
    init(contentViewController: NSViewController) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .aqua)
    }

    override var canBecomeKey: Bool { true }
}

/// Sits over the row of faces and takes files dragged onto it. Clicks pass straight through.
final class DropCatcher: NSView {
    var dropped: (([URL], CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        dropped?(urls, convert(sender.draggingLocation, from: nil).x)
        return true
    }
}
