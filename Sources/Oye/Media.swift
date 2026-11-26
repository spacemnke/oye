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

    /// 100 MB, the same as the storage bucket allows.
    static let largestFile = 100 * 1024 * 1024

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

    private struct TooBig: Error {}

    private func upload(_ file: URL, kind: Message.Kind, name: String?, seconds: Double?, contentType: String, to id: UUID) async throws {
        guard let me else { return }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.largestFile else { throw TooBig() }
        let path = Labels.storagePath(sender: me.id, recipient: id, id: UUID(), fileExtension: file.pathExtension)
        try await client.storage.from("oye").upload(path, data: data, options: FileOptions(contentType: contentType))
        let new = NewMedia(sender: me.id, recipient: id, kind: kind.rawValue, path: path, fileName: name, bytes: data.count, seconds: seconds)
        let row: MessageRow = try await client.from("oye_messages")
            .insert(new, returning: .representation)
            .select()
            .single()
            .execute().value
        conversations.add(row.message, me: me.id)
        // What you just sent is already on this Mac.
        localFiles[row.id] = file
    }

    private func addLocal(_ kind: Message.Kind, to id: UUID, name: String?, bytes: Int?, seconds: Double?, file: URL?) {
        guard let me else { return }
        let message = Message(id: UUID(), sender: me.id, recipient: id, kind: kind, fileName: name, bytes: bytes,
                              seconds: seconds, createdAt: Date())
        conversations.add(message, me: me.id)
        if let file { localFiles[message.id] = file }
    }

    static func describeSend(_ error: Error) -> String {
        if error is TooBig { return "That's over 100 MB, which is too big to send." }
        return "That didn't send. " + describe(error)
    }

    // MARK: Opening

    /// The file behind a message, on this Mac: already here if you sent it, downloaded if not.
    func file(for message: Message) async -> URL? {
        if let known = localFiles[message.id], FileManager.default.fileExists(atPath: known.path) { return known }
        guard !Self.isDemo, let path = message.path else { return nil }
        do {
            let data = try await client.storage.from("oye").download(path: path)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oye-received", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(message.id.uuidString.lowercased()).appendingPathExtension((path as NSString).pathExtension)
            try data.write(to: url, options: .atomic)
            localFiles[message.id] = url
            return url
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
