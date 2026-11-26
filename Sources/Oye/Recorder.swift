import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import OyeCore

/// Records the three things you can send: your voice, your camera, or your screen. Each one
/// writes a file; `stop` hands it back.
@MainActor
final class Recorder: NSObject, ObservableObject {
    enum Problem: LocalizedError {
        case microphoneOff, cameraOff, screenOff, noMicrophone, noCamera, needsNewerMac, failed

        var errorDescription: String? {
            switch self {
            case .microphoneOff: return "Oye isn't allowed to use the microphone. Turn it on in System Settings, Privacy & Security."
            case .cameraOff: return "Oye isn't allowed to use the camera. Turn it on in System Settings, Privacy & Security."
            case .screenOff: return "Oye isn't allowed to record the screen. Turn it on in System Settings, Privacy & Security, then try again."
            case .noMicrophone: return "No microphone found."
            case .noCamera: return "No camera found."
            case .needsNewerMac: return "Screen recording needs macOS 15 or later."
            case .failed: return "That recording didn't work. Try again."
            }
        }
    }

    /// How loud your voice is right now, 0 to 1, while recording a voice note.
    @Published private(set) var level: Double = 0
    /// The camera, while it's on, for the preview.
    @Published private(set) var camera: AVCaptureSession?

    private var voice: AVAudioRecorder?
    private var meter: Timer?
    private var movie: AVCaptureMovieFileOutput?
    private var movieDone: CheckedContinuation<Bool, Never>?
    private var screen: AnyObject?
    private var file: URL?

    private static func newFile(_ kind: Capture.Kind) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("oye-" + UUID().uuidString.lowercased())
            .appendingPathExtension(kind.fileExtension)
    }

    func start(_ kind: Capture.Kind) async throws {
        let url = Self.newFile(kind)
        switch kind {
        case .voice:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Problem.microphoneOff }
            try startVoice(to: url)
        case .video:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw Problem.cameraOff }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Problem.microphoneOff }
            try await startCamera(to: url)
        case .screen:
            guard #available(macOS 15.0, *) else { throw Problem.needsNewerMac }
            // The microphone goes with it, so you can talk over what you're showing.
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Problem.microphoneOff }
            try await startScreen(to: url)
        }
        file = url
    }

    /// Stops whatever is recording and returns its file, or nil if nothing usable was written.
    func stop() async -> URL? {
        let url = file
        file = nil
        if let voice {
            voice.stop()
            self.voice = nil
            meter?.invalidate()
            meter = nil
            level = 0
        }
        if let movie {
            let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                movieDone = done
                movie.stopRecording()
            }
            self.movie = nil
            stopCamera()
            if !ok { return nil }
        }
        if #available(macOS 15.0, *), let screen = screen as? ScreenRecording {
            self.screen = nil
            await screen.stop()
        }
        guard let url, let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 0 else { return nil }
        return url
    }

    /// Stops and throws the file away.
    func cancel() async {
        if let url = await stop() { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Voice

    private func startVoice(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw Problem.noMicrophone }
        voice = recorder
        meter = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let voice = self.voice else { return }
                voice.updateMeters()
                // -50 dB and below reads as silence; 0 dB is full.
                self.level = max(0, min(1, (Double(voice.averagePower(forChannel: 0)) + 50) / 50))
            }
        }
    }

    // MARK: Camera

    private func startCamera(to url: URL) async throws {
        guard let lens = AVCaptureDevice.default(for: .video) else { throw Problem.noCamera }
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw Problem.noMicrophone }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        let output = AVCaptureMovieFileOutput()
        let videoIn = try AVCaptureDeviceInput(device: lens)
        let audioIn = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(videoIn), session.canAddInput(audioIn), session.canAddOutput(output) else { throw Problem.failed }
        session.addInput(videoIn)
        session.addInput(audioIn)
        session.addOutput(output)
        // Starting the camera blocks for a moment, so it happens off the main thread.
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                ready.resume()
            }
        }
        guard session.isRunning else { throw Problem.failed }
        camera = session
        movie = output
        output.startRecording(to: url, recordingDelegate: self)
    }

    private func stopCamera() {
        guard let session = camera else { return }
        camera = nil
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    // MARK: Screen

    @available(macOS 15.0, *)
    private func startScreen(to url: URL) async throws {
        let recording = ScreenRecording()
        do {
            try await recording.start(to: url)
        } catch {
            throw Problem.screenOff
        }
        screen = recording
    }
}

extension Recorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // A recording that hit a limit still reports an error but leaves a good file.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
        let ok = error == nil || finished == true
        Task { @MainActor in
            self.movieDone?.resume(returning: ok)
            self.movieDone = nil
        }
    }
}

/// The main display, without Oye's own windows, with your microphone, written straight to a file.
@available(macOS 15.0, *)
private final class ScreenRecording: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private var stream: SCStream?
    private var output: SCRecordingOutput?

    func start(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw Recorder.Problem.failed
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let settings = SCStreamConfiguration()
        // Sharp on a Retina display, but no wider than 2560 so files stay sendable.
        let scale = min(2.0, 2560.0 / Double(max(display.width, 1)))
        settings.width = Int(Double(display.width) * scale)
        settings.height = Int(Double(display.height) * scale)
        settings.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        settings.showsCursor = true
        settings.captureMicrophone = true
        let stream = SCStream(filter: filter, configuration: settings, delegate: self)
        let file = SCRecordingOutputConfiguration()
        file.outputURL = url
        file.outputFileType = .mov
        file.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: file, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        // Stopping the capture finishes the file.
        try? await stream.stopCapture()
        output = nil
    }
}

/// The live camera picture, for the panel while you record a video message.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}
