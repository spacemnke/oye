import AppKit
import AVFoundation
import Supabase
import UniformTypeIdentifiers
import OyeCore

/// Recording, sending and opening the things that aren't text: voice notes, camera messages,
/// screen recordings and files.
extension Store {
    // MARK: Recording

    func startRecording(_ kind: Capture.Kind, for id: UUID) {
        guard capture.isIdle, !startingCapture else { return }
        notice = nil
        startingCapture = true
        Task {
            defer { startingCapture = false }
            if !Self.isDemo {
                do {
                    try await recorder.start(kind)
                } catch {
                    notice = (error as? LocalizedError)?.errorDescription ?? "That recording didn't start. Try again."
                    return
                }
            }
            capture.start(kind, for: id, now: Date())
            watchCapture()
        }
    }

    /// Ticks while recording so the timer moves, and stops it at the limit.
    private func watchCapture() {
        captureWatch?.cancel()
        captureWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled, self.capture.recording != nil else { return }
                self.captureNow = Date()
                if self.capture.isOver(now: self.captureNow) { self.stopRecording() }
            }
        }
    }

    func stopRecording() {
        guard capture.recording != nil, !stoppingCapture else { return }
        stoppingCapture = true
        captureWatch?.cancel()
        Task {
            defer { stoppingCapture = false }
            let url = Self.isDemo ? nil : await recorder.stop()
            let kept = capture.stop(now: Date())
            if kept, !Self.isDemo, url == nil {
                capture.clear()
                notice = "That recording didn't work. Try again."
            } else if kept {
                recorded = url
            } else if let url {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func discardRecording() {
        captureWatch?.cancel()
        let file = recorded
        recorded = nil
        let wasRecording = capture.recording != nil
        capture.clear()
        Task {
            if wasRecording, !Self.isDemo { await recorder.cancel() }
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The recording you're looking at, for playing it back before sending.
    var recordedFile: URL? { recorded }

    func sendRecording() {
        guard case .review(let kind, let seconds) = capture.phase, let id = capture.target, !sending else { return }
        let file = recorded
        if Self.isDemo {
            addLocal(kind.messageKind, to: id, name: nil, bytes: nil, seconds: seconds, file: nil)
            recorded = nil
            capture.clear()
            return
        }
        guard let file else {
            capture.clear()
            return
        }
        sending = true
        Task {
            defer { sending = false }
            do {
                try await upload(file, kind: kind.messageKind, name: nil, seconds: seconds, contentType: kind.contentType, to: id)
                recorded = nil
                capture.clear()
            } catch {
                // Still in review, so it can be sent again.
                notice = Self.describeSend(error)
            }
        }
    }

    // MARK: Files

    func sendFiles(_ urls: [URL], to id: UUID) {
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                notice = "Folders can't be sent yet. Zip it first."
                continue
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if Self.isDemo {
                addLocal(.file, to: id, name: url.lastPathComponent, bytes: bytes, seconds: nil, file: url)
                continue
            }
            Task {
                do {
                    let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    try await upload(url, kind: .file, name: url.lastPathComponent, seconds: nil, contentType: type, to: id)
                } catch {
                    notice = Self.describeSend(error)
                }
            }
        }
    }

    /// Asks which files to send.
    func chooseFiles(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        sendFiles(panel.urls, to: id)
    }

    // MARK: Sending

    private struct NewMedia: Encodable {
        let sender: UUID
        let recipient: UUID
        let kind: String
        let path: String
        let fileName: String?
        let bytes: Int
        let seconds: Double?
        enum CodingKeys: String, CodingKey {
            case sender, recipient, kind, path, bytes, seconds
            case fileName = "file_name"
        }
    }

    /// Puts the file on the file server, then adds the message that points at it.
    func upload(_ file: URL, kind: Message.Kind, name: String?, seconds: Double?, contentType: String, to id: UUID) async throws {
        guard let me else { return }
        let label: String
        switch kind {
        case .voice: label = "voice note"
        case .video: label = "video"
        case .screen: label = "screen recording"
        default: label = name ?? file.lastPathComponent
        }
        let sent = try await push(file, name: label, type: contentType, to: id)
        let new = NewMedia(sender: me.id, recipient: id, kind: kind.rawValue, path: sent.key, fileName: name, bytes: sent.size, seconds: seconds)
        let row: MessageRow = try await client.from("oye_messages")
            .insert(new, returning: .representation)
            .select()
            .single()
            .execute().value
        conversations.add(row.message, me: me.id)
        // What you just sent is already on this Mac. A recording lives in a temporary file, so it's
        // kept somewhere lasting: you can still play it after the server's copy has gone.
        localFiles[row.id] = file
        if kind != .file {
            let keep = keptCopy(of: row.message)
            try? FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: file, to: keep)) != nil { localFiles[row.id] = keep }
        }
    }

    // MARK: A link for anyone

    /// Puts files on the server for anyone with the link, and copies the links. They work for three days.
    @discardableResult
    func share(_ urls: [URL]) async -> [String] {
        guard me != nil, !Self.isDemo else { return [] }
        notice = nil
        var made: [String] = []
        let invite = await inviteForLinks()
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                notice = "Folders can't be sent yet. Zip it first."
                continue
            }
            do {
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let sent = try await push(url, name: url.lastPathComponent, type: type, to: nil, invite: invite)
                if let link = sent.link { made.append(link) }
            } catch {
                notice = Self.describeSend(error)
            }
        }
        if !made.isEmpty {
            links = made
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(made.joined(separator: "\n"), forType: .string)
        }
        return made
    }

    /// Asks which file to make a link for.
    func chooseFilesToShare() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Make link"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await share(urls) }
    }

    private func addLocal(_ kind: Message.Kind, to id: UUID, name: String?, bytes: Int?, seconds: Double?, file: URL?) {
        guard let me else { return }
        let message = Message(id: UUID(), sender: me.id, recipient: id, kind: kind, fileName: name, bytes: bytes,
                              seconds: seconds, createdAt: Date())
        conversations.add(message, me: me.id)
        if let file { localFiles[message.id] = file }
    }

    static func describeSend(_ error: Error) -> String {
        switch error as? FileProblem {
        case .tooBig?: return "That's over 1 GB, which is too big to send."
        case .empty?: return "That file is empty."
        case .tooMuchWaiting?: return "You have a lot waiting to be picked up. Try again once some of it has been."
        case .notAllowed?: return "That didn't send. They're no longer one of your people."
        default: return "That didn't send. " + describe(error)
        }
    }

    // MARK: Opening

    private func named(_ message: Message, in folder: URL) -> URL {
        let ext = ((message.path ?? "") as NSString).pathExtension
        let url = folder.appendingPathComponent(message.id.uuidString.lowercased())
        return ext.isEmpty ? url : url.appendingPathExtension(ext)
    }

    /// Where a recording you sent is kept on this Mac.
    func keptCopy(of message: Message) -> URL { named(message, in: Prefs.folder("Sent", in: .applicationSupportDirectory)) }

    /// Where something you received sits once you've opened it.
    private func receivedCopy(of message: Message) -> URL { named(message, in: Prefs.folder("Received", in: .cachesDirectory)) }

    /// The file behind a message if it's already on this Mac.
    func localCopy(of message: Message) -> URL? {
        if let known = localFiles[message.id], FileManager.default.fileExists(atPath: known.path) { return known }
        return [keptCopy(of: message), receivedCopy(of: message)].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Its three days on the server are up and there's no copy on this Mac.
    func isGone(_ message: Message) -> Bool {
        !Self.isDemo && message.hasExpired(now: clock) && localCopy(of: message) == nil
    }

    /// The file behind a message, on this Mac: already here if you sent or opened it, downloaded if not.
    func file(for message: Message) async -> URL? {
        if let local = localCopy(of: message) { return local }
        guard !Self.isDemo, let path = message.path else { return nil }
        do {
            let url = receivedCopy(of: message)
            if path.hasPrefix("p/") {
                try await pull(path, to: url)
            } else {
                // Sent before files moved to the file server.
                let data = try await client.storage.from("oye").download(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            localFiles[message.id] = url
            return url
        } catch FileProblem.expired {
            notice = "That's expired. Files are kept for 3 days."
            return nil
        } catch {
            notice = "Couldn't get that. " + Self.describe(error)
            return nil
        }
    }

    /// Plays a voice note, or stops it if it's the one playing.
    func toggleVoice(_ message: Message) {
        if playing == message.id {
            voicePlayer?.stop()
            playing = nil
            return
        }
        voicePlayer?.stop()
        playing = message.id
        Task {
            guard let url = await file(for: message), playing == message.id,
                  let player = try? AVAudioPlayer(contentsOf: url) else {
                if playing == message.id { playing = nil }
                return
            }
            voicePlayer = player
            player.play()
            // Clear the playing mark when it reaches the end.
            let length = player.duration
            try? await Task.sleep(nanoseconds: UInt64((length + 0.2) * 1_000_000_000))
            if playing == message.id, voicePlayer === player, !player.isPlaying { playing = nil }
        }
    }

    /// Saves a received file to Downloads and shows it in the Finder.
    func saveToDownloads(_ message: Message) {
        Task {
            guard let source = await file(for: message),
                  let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
            let name = message.fileName ?? source.lastPathComponent
            var target = downloads.appendingPathComponent(name)
            var count = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                target = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(count)" : "\(base) \(count).\(ext)")
                count += 1
            }
            do {
                try FileManager.default.copyItem(at: source, to: target)
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                notice = "Couldn't save that to Downloads."
            }
        }
    }
}
