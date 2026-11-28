import SwiftUI
import AVKit
import OyeCore

/// The panel under a face: who they are, the thread, and one place to text, record or send a file.
struct ChatView: View {
    @ObservedObject var store: Store
    @ObservedObject private var recorder: Recorder
    let personID: UUID
    @State private var draft = ""
    @State private var reviewPlayer: AVPlayer?
    @FocusState private var typing: Bool

    init(store: Store, personID: UUID) {
        self.store = store
        self.recorder = store.recorder
        self.personID = personID
    }

    private var person: Person? { store.person(personID) }
    private var thread: [Message] { store.conversations.thread(with: personID) }
    /// "Ines Marin" is texted as "Ines".
    private var firstName: String { person?.name.split(separator: " ").first.map(String.init) ?? "them" }
    /// A recording for this person is under way or waiting to be sent.
    private var mine: Bool { store.capture.target == personID }
    /// A recording for someone else is: one at a time.
    private var busyElsewhere: Bool { !store.capture.isIdle && !mine }

    var body: some View {
        PanelShell {
            VStack(alignment: .leading, spacing: 16) {
                header
                messages
                composer
                if let notice = store.notice {
                    Text(notice)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 6)
                }
            }
        }
        // Drop files anywhere on the panel to send them.
        .dropDestination(for: URL.self) { urls, _ in
            guard person != nil, store.capture.isIdle else { return false }
            store.sendFiles(urls, to: personID)
            return true
        }
        .onAppear { typing = true }
        .onChange(of: thread.count) { _, _ in store.markRead(personID) }
    }

    // MARK: Header and thread

    private var header: some View {
        HStack(spacing: 12) {
            if let person {
                FaceView(person: person, photo: store.photo(for: person), size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(Theme.font(18, .semibold))
                        .foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.talkingTo == personID ? Theme.accent : store.isHere(person) ? Theme.here : Theme.muted.opacity(0.5))
                            .frame(width: 8, height: 8)
                        Text(store.talkingTo == personID ? "Listening" : store.isHere(person) ? "Here now" : "Away")
                            .font(Theme.font(14))
                            .foregroundStyle(Theme.muted)
                    }
                }
            } else {
                Text("No longer in your menu bar")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
    }

    /// The thread hugs its bubbles until it's taller than this, then scrolls.
    private static let tallest: CGFloat = 340

    private var bubbles: some View {
        VStack(spacing: 8) {
            if thread.isEmpty {
                Text("Say oye.")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(thread) { message in
                Bubble(store: store, message: message, mine: message.sender != personID)
                    .id(message.id)
            }
            // Files on their way to them.
            ForEach(store.transfers.filter { $0.to == personID }) { transfer in
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text("Sending \(transfer.name) · \(Labels.percent(transfer.fraction))")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 264, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if store.talkingTo == personID {
            // While you hold to talk, the thread makes way for the live line.
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    LevelBars(level: 0.7, colour: Theme.accent, lively: true)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Circle().fill(Color.white).frame(width: 8, height: 8)
                        Text("Live").font(Theme.font(14, .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(Theme.accent))
                }
                Text("Talking to \(firstName). Let go to stop.")
                    .font(Theme.font(18))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        } else {
            // A hidden copy of the bubbles sets the height (capped); the real ones scroll on top of it.
            CapHeight(cap: Self.tallest) {
                bubbles.hidden()
            }
            .clipped()
            .overlay {
                ScrollViewReader { proxy in
                    ScrollView {
                        bubbles
                    }
                    // With a mouse plugged in, macOS keeps a scroll bar on show, and it sat on the bubbles.
                    .scrollIndicators(.never)
                    .onAppear { scrollToEnd(proxy) }
                    .onChange(of: thread.count) { _, _ in scrollToEnd(proxy) }
                }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = thread.last else { return }
        DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    // MARK: Composer

    @ViewBuilder private var composer: some View {
        if mine, let kind = store.capture.recording {
            recording(kind)
        } else if mine, case .review(let kind, let seconds) = store.capture.phase {
            review(kind, seconds: seconds)
        } else {
            idle
        }
    }

    /// Nothing being recorded: text, the four things you can send, and hold to talk.
    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $draft, prompt: Text("Text \(firstName)").foregroundColor(Theme.muted))
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(Theme.font(16))
                .foregroundStyle(Theme.ink)
                .focused($typing)
                .onSubmit(send)
                .padding(.horizontal, 20)
                .frame(height: 52)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            HStack(spacing: 8) {
                round(.mic, label: "Record a voice note") { store.startRecording(.voice, for: personID) }
                round(.camera, label: "Record a video message") { store.startRecording(.video, for: personID) }
                round(.screen, label: "Record your screen") { store.startRecording(.screen, for: personID) }
                round(.clip, label: "Send a file") { store.chooseFiles(for: personID) }
                HoldToTalk(live: store.talkingTo == personID) { down in
                    if down { store.startTalking(to: personID) } else { store.stopTalking() }
                }
            }
            .disabled(person == nil || busyElsewhere)
            .opacity(busyElsewhere ? 0.5 : 1)
        }
    }

    /// Recording: stop on the left, what's happening in the middle, throw it away on the right.
    private func recording(_ kind: Capture.Kind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if kind == .video {
                Group {
                    if let session = recorder.camera {
                        CameraPreview(session: session)
                    } else {
                        ZStack {
                            Theme.ink
                            Icon(kind: .camera, size: 28).foregroundStyle(Color.white.opacity(0.6))
                        }
                    }
                }
                .frame(height: 279)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            HStack(spacing: 8) {
                Button { store.stopRecording() } label: {
                    Icon(kind: .stop)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Theme.ink))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
                HStack(spacing: 10) {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    Text(Self.doing(kind))
                        .font(Theme.font(16))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    if kind == .voice { LevelBars(level: recorder.level, colour: Theme.ink, lively: false).frame(height: 24) }
                    Text(Labels.time(store.capture.elapsed(now: store.captureNow)))
                        .font(Theme.font(16))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 20)
                .frame(height: 52)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                round(.close, label: "Discard the recording") { store.discardRecording() }
            }
        }
    }

    private static func doing(_ kind: Capture.Kind) -> String {
        switch kind {
        case .voice: return "Recording"
        case .video: return "Recording video"
        case .screen: return "Recording your screen"
        }
    }

    /// Recorded: play it back, then send it or throw it away.
    private func review(_ kind: Capture.Kind, seconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if kind == .voice {
                HStack(spacing: 10) {
                    Button { toggleReview() } label: {
                        Icon(kind: .play)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.ink))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play the voice note")
                    VoiceBars()
                    Spacer(minLength: 0)
                    Text(Labels.time(seconds))
                        .font(Theme.font(16))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                .padding(.leading, 8)
                .padding(.trailing, 20)
                .frame(height: 52)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            } else {
                Group {
                    if let reviewPlayer {
                        VideoPlayer(player: reviewPlayer)
                    } else {
                        MediaTile(kind: kind.messageKind, seconds: seconds)
                    }
                }
                .frame(height: 279)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            HStack(spacing: 8) {
                Button { store.discardRecording() } label: {
                    Text("Discard")
                        .font(Theme.font(16, .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 24)
                        .frame(height: 52)
                        .background(Capsule().fill(Color.white))
                        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { store.sendRecording() } label: {
                    Text(store.sending ? "Sending" : "Send to \(firstName)")
                        .font(Theme.font(16, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(Theme.ink))
                }
                .buttonStyle(.plain)
            }
            .disabled(store.sending)
        }
        .onAppear { reviewPlayer = store.recordedFile.map { AVPlayer(url: $0) } }
        .onDisappear {
            reviewPlayer?.pause()
            reviewPlayer = nil
        }
    }

    private func toggleReview() {
        guard let reviewPlayer else { return }
        if reviewPlayer.rate > 0 {
            reviewPlayer.pause()
        } else {
            reviewPlayer.seek(to: .zero)
            reviewPlayer.play()
        }
    }

    private func round(_ kind: Icon.Kind, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(kind: kind)
                .foregroundStyle(Theme.ink)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.white))
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func send() {
        guard person != nil, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.send(draft, to: personID)
        draft = ""
        typing = true
    }
}

/// Hold to talk: live while the button is held down, and only then.
private struct HoldToTalk: View {
    let live: Bool
    let changed: (Bool) -> Void
    @State private var down = false

    var body: some View {
        HStack(spacing: 8) {
            Icon(kind: .wave)
            Text(live ? "Live" : "Hold to talk")
                .font(Theme.font(16, .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(Capsule().fill(live ? Theme.accent : Theme.ink))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !down {
                        down = true
                        changed(true)
                    }
                }
                .onEnded { _ in
                    down = false
                    changed(false)
                }
        )
        .accessibilityLabel("Hold to talk")
        .accessibilityAddTraits(.isButton)
    }
}

/// The waveform of a voice note, as in the designs.
struct VoiceBars: View {
    private static let bars: [CGFloat] = [6, 12, 18, 9, 14, 20, 11, 7, 15, 10, 17, 8, 13, 6]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, tall in
                RoundedRectangle(cornerRadius: 2).fill(Theme.ink).frame(width: 3, height: tall)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Bars that follow a level: your voice while recording, or the line while you hold to talk.
struct LevelBars: View {
    let level: Double
    let colour: Color
    /// The taller, steadier bars of the live line; otherwise small ones that track your voice.
    let lively: Bool
    private static let shape: [CGFloat] = [0.27, 0.54, 0.85, 0.42, 1, 0.65, 0.35, 0.77, 0.5, 0.23, 0.58, 0.88, 0.38, 0.69, 0.31]

    var body: some View {
        let tallest: CGFloat = lively ? 52 : 24
        HStack(spacing: lively ? 5 : 3) {
            ForEach(Array(Self.shape.prefix(lively ? 15 : 10).enumerated()), id: \.offset) { _, part in
                RoundedRectangle(cornerRadius: 3)
                    .fill(colour)
                    .frame(width: lively ? 5 : 3, height: max(3, tallest * part * CGFloat(max(0.15, level))))
            }
        }
        .frame(height: tallest)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

/// A camera message or screen recording before it's playing: a dark tile with what it is.
struct MediaTile: View {
    let kind: Message.Kind
    let seconds: Double?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.ink
            Icon(kind: .play, size: 22)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 6) {
                Icon(kind: kind == .screen ? .screen : .camera, size: 14)
                Text(Labels.time(seconds ?? 0))
                    .font(Theme.font(12))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(12)
        }
    }
}

/// One message. Yours sit on the right in indigo; theirs on the left in white, with one squared-off
/// corner pointing at whoever sent it.
private struct Bubble: View {
    @ObservedObject var store: Store
    let message: Message
    let mine: Bool
    @State private var player: AVPlayer?

    var body: some View {
        HStack(spacing: 0) {
            if mine { Spacer(minLength: 0) }
            // Bubbles hug their words up to the design's width, then wrap.
            content.frame(maxWidth: 264, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder private var content: some View {
        if store.isGone(message) {
            // Its three days are up and it was never opened on this Mac.
            HStack(spacing: 10) {
                Icon(kind: .file).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.fileName ?? goneName)
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Expired")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .help("Files, voice notes and recordings are kept for 3 days.")
        } else {
            live
        }
    }

    private var goneName: String {
        switch message.kind {
        case .voice: return "Voice note"
        case .video: return "Video"
        case .screen: return "Screen recording"
        default: return "File"
        }
    }

    @ViewBuilder private var live: some View {
        switch message.kind {
        case .text:
            Text(message.body)
                .font(Theme.font(14))
                .lineSpacing(2)
                .foregroundStyle(mine ? Color.white : Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(shape.fill(mine ? Theme.accent : Color.white))
                .overlay(shape.stroke(mine ? Color.clear : Theme.line, lineWidth: 1))
        case .file:
            Button { store.saveToDownloads(message) } label: {
                HStack(spacing: 10) {
                    Icon(kind: .file).foregroundStyle(Theme.ink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.fileName ?? "File")
                            .font(Theme.font(14, .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(message.bytes.map(Labels.size) ?? "")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Save to Downloads")
        case .voice:
            HStack(spacing: 10) {
                Button { store.toggleVoice(message) } label: {
                    Icon(kind: store.playing == message.id ? .stop : .play, size: 14)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.ink))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.playing == message.id ? "Stop" : "Play voice note")
                VoiceBars()
                Text(Labels.time(message.seconds ?? 0))
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(shape.fill(Color.white))
            .overlay(shape.stroke(Theme.line, lineWidth: 1))
        case .video, .screen:
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Button { play() } label: { MediaTile(kind: message.kind, seconds: message.seconds) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(message.kind == .screen ? "Play screen recording" : "Play video message")
                }
            }
            .frame(width: 264, height: 165)
            .clipShape(shape)
        }
    }

    private func play() {
        Task {
            guard let url = await store.file(for: message) else { return }
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
    }

    /// 16-point corners, 4 on the corner nearest the sender.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: mine ? 16 : 4,
                               bottomTrailingRadius: mine ? 4 : 16, topTrailingRadius: 16, style: .continuous)
    }
}
