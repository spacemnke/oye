import Foundation
import AppKit
import AVFoundation
import Supabase
import OyeCore

/// Everything Oye knows: who you are, your people, and the threads with them. Turns what arrives
/// from the network into changes the menu bar and panels show, and what you do into network calls.
@MainActor
final class Store: ObservableObject {
    enum Status: Equatable {
        case connecting
        case online
        case offline(String)
    }

    @Published private(set) var status: Status = .connecting
    @Published var me: Person?
    @Published private(set) var people: [Person] = []
    @Published var conversations = Conversations()
    /// Your current invite code, once you've asked for one.
    @Published private(set) var inviteCode: String?
    /// One line about the last thing that happened ("Linked with Ines", "Wrong or expired invite").
    @Published var notice: String?
    /// Bumped every ten seconds so "here now" stays current without a check-in arriving.
    @Published private(set) var clock = Date()

    private static let nameKey = "oye.myName"
    var myName: String { Self.isDemo ? "You" : Prefs.store.string(forKey: Self.nameKey) ?? "" }

    /// Demo mode (OYE_DEMO=1): placeholder people and threads, and nothing touches the network.
    /// Used for screenshots and for looking at the app without an account.
    static let isDemo = ProcessInfo.processInfo.environment["OYE_DEMO"] != nil

    let client = Backend.client()

    // Recording and media (the doing is in Media.swift).
    @Published var capture = Capture()
    /// The time as of the last tick while recording, for the timer.
    @Published var captureNow = Date()
    @Published var sending = false
    /// The voice note that's playing, if any.
    @Published var playing: UUID?
    let recorder = Recorder()
    var recorded: URL?
    var captureWatch: Task<Void, Never>?
    var startingCapture = false
    var stoppingCapture = false
    var localFiles: [UUID: URL] = [:]
    /// Files on their way up, for the progress lines.
    @Published var transfers: [Transfer] = []
    /// The links you last made for sending to anyone.
    @Published var links: [String] = []
    var voicePlayer: AVAudioPlayer?

    // Hold to talk (the doing is in Talk.swift).
    /// Who you're talking to right now, while you hold.
    @Published var talkingTo: UUID?
    /// Whose line you're on, listening.
    @Published var hearing: UUID?
    let line = TalkLine()
    var talkIdle: Task<Void, Never>?
    private static let dndKey = "oye.doNotDisturb"
    /// On do not disturb, nobody's voice comes out of this Mac.
    @Published var doNotDisturb = Prefs.store.bool(forKey: Store.dndKey) {
        didSet { Prefs.store.set(doNotDisturb, forKey: Self.dndKey) }
    }

    init() {
        line.onAlone = { [weak self] in self?.lineWentQuiet() }
    }
    private var channel: RealtimeChannelV2?
    private var listeners: [Task<Void, Never>] = []
    private var heartbeat: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    /// An invite opened before sign-in finished waits here.
    private var pendingInvite: String?

    // MARK: Rows

    private struct PersonRow: Decodable {
        let id: UUID
        let name: String
        let lastSeen: String?
        enum CodingKeys: String, CodingKey {
            case id, name
            case lastSeen = "last_seen"
        }
        var person: Person { Person(id: id, name: name, lastSeen: lastSeen.flatMap(Stamp.parse)) }
    }

    struct MessageRow: Decodable {
        let id: UUID
        let sender: UUID
        let recipient: UUID
        let kind: String
        let body: String
        let path: String?
        let fileName: String?
        let bytes: Int?
        let seconds: Double?
        let createdAt: String
        let readAt: String?
        enum CodingKeys: String, CodingKey {
            case id, sender, recipient, kind, body, path, bytes, seconds
            case fileName = "file_name"
            case createdAt = "created_at"
            case readAt = "read_at"
        }
        var message: Message {
            Message(id: id, sender: sender, recipient: recipient, kind: Message.Kind(rawValue: kind) ?? .text,
                    body: body, fileName: fileName, bytes: bytes, seconds: seconds, path: path,
                    createdAt: Stamp.parse(createdAt) ?? Date(), readAt: readAt.flatMap(Stamp.parse))
        }
    }

    private struct NewMessage: Encodable {
        let sender: UUID
        let recipient: UUID
        let kind: String
        let body: String
    }

    // MARK: Connecting

    func start() {
        if Self.isDemo {
            loadDemo()
            return
        }
        guard !myName.isEmpty else {
            status = .offline("Tell Oye your name to get started")
            return
        }
        retry?.cancel()
        status = .connecting
        Task { await connect() }
    }

    /// First run, or a new name later.
    func setName(_ name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !clean.isEmpty else { return }
        Prefs.store.set(clean, forKey: Self.nameKey)
        start()
    }

    private func connect() async {
        await teardown()
        do {
            if (try? await client.auth.session) == nil {
                _ = try await client.auth.signInAnonymously()
            }
            let row: PersonRow = try await client.rpc("oye_ensure_person", params: ["display_name": myName]).execute().value
            me = row.person
            if inviteCode == nil { inviteCode = savedInvite(goodFor: 0.5) }
            try await loadPeople()
            try await loadMessages()
            try await listen(me: row.id)
            status = .online
            startHeartbeat()
            if let code = pendingInvite {
                pendingInvite = nil
                join(code)
            }
        } catch {
            status = .offline(Self.describe(error))
            retry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.connect()
            }
        }
    }

    private func teardown() async {
        heartbeat?.cancel()
        heartbeat = nil
        for task in listeners { task.cancel() }
        listeners = []
        await client.removeAllChannels()
        channel = nil
    }

    /// Quitting: tell people you've gone, so you show as away at once rather than after a minute.
    func signOff(timeout: TimeInterval) async {
        heartbeat?.cancel()
        guard me != nil, !Self.isDemo else { return }
        let client = self.client
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await client.rpc("oye_sign_off").execute() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    static func describe(_ error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("wrong or expired invite") { return "Wrong or expired invite" }
        if text.contains("your own invite") { return "That's your own invite" }
        if text.contains("too many") { return "That's the limit for now" }
        if text.contains("anonymous") { return "Sign-ins are switched off on the server" }
        if text.contains("oye_") { return "Oye's server isn't set up yet" }
        if error is URLError || text.contains("offline") || text.contains("network") { return "No connection" }
        return "Couldn't reach Oye's server"
    }

    // MARK: Loading

    private func loadPeople() async throws {
        guard let me else { return }
        // Row-level security returns you and the people you're linked to.
        let rows: [PersonRow] = try await client.from("oye_people").select("id, name, last_seen").execute().value
        let known = Set(people.map(\.id))
        people = rows.map(\.person).filter { $0.id != me.id }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for gone in known.subtracting(people.map(\.id)) { conversations.forget(gone) }
    }

    private func loadMessages() async throws {
        guard let me else { return }
        let rows: [MessageRow] = try await client.from("oye_messages").select()
            .order("created_at", ascending: false)
            .limit(500)
            .execute().value
        var all = Conversations()
        for row in rows { all.add(row.message, me: me.id) }
        conversations = all
    }

    // MARK: Listening

    /// One channel for everything live: messages to you, read receipts on yours, new links, check-ins.
    private func listen(me: UUID) async throws {
        for task in listeners { task.cancel() }
        listeners = []
        if let old = channel {
            channel = nil
            await client.removeChannel(old)
        }
        let id = me.uuidString.lowercased()
        let channel = client.channel("oye-\(id)")
        let toMe = channel.postgresChange(InsertAction.self, schema: "public", table: "oye_messages", filter: .eq("recipient", value: id))
        let mineChanged = channel.postgresChange(UpdateAction.self, schema: "public", table: "oye_messages", filter: .eq("sender", value: id))
        let linked = channel.postgresChange(InsertAction.self, schema: "public", table: "oye_links", filter: .eq("owner", value: id))
        // Row-level security limits these to you and the people you're linked to.
        let checkIns = channel.postgresChange(UpdateAction.self, schema: "public", table: "oye_people")
        let talks = channel.postgresChange(InsertAction.self, schema: "public", table: "oye_talks", filter: .eq("callee", value: id))
        listeners.append(Task { [weak self] in
            for await action in toMe { self?.arrived(try? action.decodeRecord(as: MessageRow.self, decoder: JSONDecoder())) }
        })
        listeners.append(Task { [weak self] in
            for await action in mineChanged { self?.arrived(try? action.decodeRecord(as: MessageRow.self, decoder: JSONDecoder())) }
        })
        listeners.append(Task { [weak self] in
            for await _ in linked { try? await self?.loadPeople() }
        })
        listeners.append(Task { [weak self] in
            for await action in checkIns { self?.checkedIn(try? action.decodeRecord(as: PersonRow.self, decoder: JSONDecoder())) }
        })
        listeners.append(Task { [weak self] in
            struct TalkRow: Decodable { let caller: UUID }
            for await action in talks {
                if let row = try? action.decodeRecord(as: TalkRow.self, decoder: JSONDecoder()) { self?.heard(from: row.caller) }
            }
        })
        try await channel.subscribeWithError()
        self.channel = channel
    }

    private func arrived(_ row: MessageRow?) {
        guard let row, let me else { return }
        conversations.add(row.message, me: me.id)
    }

    private func checkedIn(_ row: PersonRow?) {
        guard let row, let at = people.firstIndex(where: { $0.id == row.id }) else { return }
        people[at] = row.person
    }

    /// Every ten seconds the clock ticks (so people who went quiet show as away); every thirty you
    /// check in and re-read your people and messages, which also catches anything the channel missed.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var beat = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { return }
                beat += 1
                self.clock = Date()
                if beat % 3 == 0 {
                    _ = try? await self.client.rpc("oye_check_in").execute()
                    try? await self.loadPeople()
                    try? await self.loadMessages()
                }
            }
        }
    }

    // MARK: Photos

    private var photos: [UUID: NSImage] = [:]

    /// Their face photo, if they have one. Real people get photos with file drops; until then
    /// only demo mode's placeholder people have them.
    func photo(for person: Person) -> NSImage? { photos[person.id] }

    // MARK: Demo

    private func loadDemo() {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        let now = Date()
        let you = Person(id: id(1), name: "You", lastSeen: now)
        let mara = Person(id: id(11), name: "Mara", lastSeen: now)
        let leo = Person(id: id(22), name: "Leo", lastSeen: now)
        let ines = Person(id: id(33), name: "Ines", lastSeen: now)
        let tom = Person(id: id(44), name: "Tom", lastSeen: now)
        me = you
        people = [mara, leo, ines, tom]
        for (person, file) in [(mara, "mara"), (leo, "leo"), (ines, "ines"), (tom, "tom")] {
            if let url = Resources.folder("Demo")?.appendingPathComponent(file + ".jpg") {
                photos[person.id] = NSImage(contentsOf: url)
            }
        }
        var all = Conversations()
        func add(_ kind: Message.Kind, _ body: String, _ from: Person, _ to: Person, _ ago: TimeInterval,
                 file: String? = nil, bytes: Int? = nil, seconds: Double? = nil) {
            all.add(Message(id: UUID(), sender: from.id, recipient: to.id, kind: kind, body: body, fileName: file,
                            bytes: bytes, seconds: seconds, createdAt: now.addingTimeInterval(-ago), readAt: now), me: you.id)
        }
        // The thread from the designs.
        add(.text, "Did the deck go out?", ines, you, 600)
        add(.text, "Sending it now", you, ines, 560)
        add(.file, "", you, ines, 540, file: "Pitch-v3.key", bytes: 4_200_000)
        add(.voice, "", ines, you, 300, seconds: 8)
        add(.text, "Got it, thanks", ines, you, 240)
        add(.text, "Running five late, start without me", tom, you, 120)
        add(.text, "Call when you're free", leo, you, 3600)
        conversations = all
        status = .online
    }

    // MARK: People

    func person(_ id: UUID) -> Person? { people.first { $0.id == id } }

    func isHere(_ person: Person) -> Bool { person.isHere(now: clock) }

    func unread(from id: UUID) -> Int {
        guard let me else { return 0 }
        return conversations.unread(from: id, me: me.id)
    }

    private static let inviteKey = "oye.invite"
    private static let inviteDateKey = "oye.inviteMade"

    /// A fresh invite code to send someone.
    func makeInvite() {
        Task { _ = await newInvite() }
    }

    private func newInvite() async -> String? {
        do {
            let code: String = try await client.rpc("oye_new_invite").execute().value
            inviteCode = code
            Prefs.store.set(code, forKey: Self.inviteKey)
            Prefs.store.set(Date(), forKey: Self.inviteDateKey)
            return code
        } catch {
            notice = Self.describe(error)
            return nil
        }
    }

    /// Your invite code as of last time, if it still has days left (codes last a week).
    private func savedInvite(goodFor days: Double) -> String? {
        guard let code = Prefs.store.string(forKey: Self.inviteKey),
              let made = Prefs.store.object(forKey: Self.inviteDateKey) as? Date,
              Date().timeIntervalSince(made) < (7 - days) * 86_400 else { return nil }
        return code
    }

    /// A code that will outlast a file link (three days), for the "add me" on the link's page.
    /// Reuses your current one where it can, so links don't use up invites.
    func inviteForLinks() async -> String? {
        if let saved = savedInvite(goodFor: 3.5) {
            if inviteCode == nil { inviteCode = saved }
            return saved
        }
        return await newInvite()
    }

    /// Someone's invite, pasted in or opened as a link.
    func join(_ text: String) {
        guard let code = Invite.code(in: text) else {
            notice = "That doesn't look like an invite"
            return
        }
        guard me != nil else {
            pendingInvite = code
            return
        }
        struct Found: Decodable { let id: UUID; let name: String }
        Task {
            do {
                let found: [Found] = try await client.rpc("oye_accept_invite", params: ["invite_code": code]).execute().value
                try await loadPeople()
                notice = found.first.map { "Linked with \($0.name)" } ?? "Linked"
            } catch {
                notice = Self.describe(error)
            }
        }
    }

    func remove(_ id: UUID) {
        Task {
            _ = try? await client.rpc("oye_unlink", params: ["friend_id": id.uuidString.lowercased()]).execute()
            try? await loadPeople()
        }
    }

    // MARK: Messages

    func send(_ text: String, to id: UUID) {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard let me, !body.isEmpty else { return }
        if Self.isDemo {
            conversations.add(Message(id: UUID(), sender: me.id, recipient: id, body: body, createdAt: Date()), me: me.id)
            return
        }
        Task {
            do {
                let row: MessageRow = try await client.from("oye_messages")
                    .insert(NewMessage(sender: me.id, recipient: id, kind: "text", body: body), returning: .representation)
                    .select()
                    .single()
                    .execute().value
                conversations.add(row.message, me: me.id)
            } catch {
                notice = Self.describe(error)
            }
        }
    }

    /// You opened their thread.
    func markRead(_ id: UUID) {
        guard let me, conversations.unread(from: id, me: me.id) > 0 else { return }
        conversations.markRead(from: id, me: me.id, now: Date())
        if Self.isDemo { return }
        Task { _ = try? await client.rpc("oye_mark_read", params: ["friend_id": id.uuidString.lowercased()]).execute() }
    }
}
