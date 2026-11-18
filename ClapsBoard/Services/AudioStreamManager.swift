//
//  AudioStreamManager.swift
//  ClapsBoard
//
//  Handles real-time audio capture and playback for VoIP voice channel
//  Optimized for peer-to-peer transmission
//

import Foundation
import AVFoundation

/// Delegate for audio stream events. Callbacks arrive on background threads.
protocol AudioStreamManagerDelegate: AnyObject {
    func audioStreamManager(_ manager: AudioStreamManager, didCaptureAudioData data: Data)
    func audioStreamManager(_ manager: AudioStreamManager, didUpdateLocalAudioLevel level: Float)
    func audioStreamManager(_ manager: AudioStreamManager, didUpdateRemoteAudioLevel level: Float, forPeer peerID: String)
    /// The engine stopped or resumed on its own (interruption, route change).
    /// `message` is set when it could not be brought back.
    func audioStreamManager(_ manager: AudioStreamManager, didChangeRunning isRunning: Bool, message: String?)
}

enum AudioStreamError: LocalizedError {
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: return "The microphone isn't available right now."
        }
    }
}

/// Manages audio capture and playback for voice communication
class AudioStreamManager: NSObject {

    // MARK: - Shared audio-session ownership

    /// True while a Voice Channel is using the shared AVAudioSession
    /// (.playAndRecord). The camera checks this and leaves the session
    /// category alone, because changing it would cut the channel's microphone.
    static var isVoiceSessionActive = false
    /// Set by CameraManager while its PiP keep-alive is running on the shared
    /// session, so ending a Voice Channel doesn't deactivate it underneath PiP.
    static var isSessionHeldByCameraPiP = false

    // MARK: - Properties
    weak var delegate: AudioStreamManagerDelegate?

    /// One player per remote peer. A single shared player queued every
    /// peer's packets one after another, so with two or more remote speakers
    /// the audio fell further and further behind.
    private final class PeerPlayer {
        let node: AVAudioPlayerNode
        var queuedFrames = 0
        /// Bumped when the queue is flushed, so stale completions are ignored.
        var epoch = 0
        init(node: AVAudioPlayerNode) { self.node = node }
    }

    /// Serialises every change to the engine and the per-peer players.
    private let engineQueue = DispatchQueue(label: "com.clapsboard.voiceEngine", qos: .userInitiated)

    private var audioEngine: AVAudioEngine?
    private var peerPlayers: [String: PeerPlayer] = [:]

    private var isCapturing = false
    private var isInterrupted = false
    private var isMuted = false
    private var lastEngineStart = Date.distantPast

    // Audio formats
    private let engineFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// Most audio a peer may have waiting to play (0.4 s). Past that the
    /// backlog is dropped so delay can't build up.
    private let maxQueuedFramesPerPeer = 6400

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleEngineConfigurationChange(_:)), name: .AVAudioEngineConfigurationChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Permission

    /// Checks (and if needed asks for) microphone access. Completion runs on the main queue.
    static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            DispatchQueue.main.async { completion(true) }
        case .denied:
            DispatchQueue.main.async { completion(false) }
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        @unknown default:
            DispatchQueue.main.async { completion(false) }
        }
    }

    // MARK: - Capture

    /// Start capturing audio from the microphone. Throws if the session or
    /// engine can't start, so the caller can show an error instead of "Live".
    func startCapturing() throws {
        try engineQueue.sync {
            guard !isCapturing else { return }
            try startEngineLocked()
        }
    }

    /// Stop capturing, release the engine and give the audio session back.
    func stopCapturing() {
        engineQueue.sync {
            guard isCapturing else { return }
            teardownEngineLocked()
            isCapturing = false
            isInterrupted = false
            Self.isVoiceSessionActive = false
            // Hand the session back so other apps' audio returns to normal —
            // unless the camera's PiP keep-alive is running on it.
            if !Self.isSessionHeldByCameraPiP {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            print("🔇 Audio engine stopped and cleaned up")
        }
    }

    /// Set mute state
    func setMuted(_ muted: Bool) {
        isMuted = muted
        // No audio is processed while muted, so the level would otherwise
        // freeze at its last value.
        if muted { delegate?.audioStreamManager(self, didUpdateLocalAudioLevel: 0) }
    }

    /// Stops and discards the player for a peer who left or was blocked.
    func removePeer(_ peerID: String) {
        engineQueue.async {
            guard let player = self.peerPlayers.removeValue(forKey: peerID) else { return }
            player.epoch += 1
            if let engine = self.audioEngine {
                if engine.isRunning { player.node.stop() }
                engine.detach(player.node)
            }
        }
    }

    // MARK: - Engine lifecycle (engineQueue only)

    private func startEngineLocked() throws {
        let session = AVAudioSession.sharedInstance()
        Self.isVoiceSessionActive = true
        let engine = AVAudioEngine()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
                .allowBluetoothA2DP,
                .defaultToSpeaker,
                .mixWithOthers
            ])
            try session.setActive(true)

            let input = engine.inputNode
            // Echo cancellation, so a student on speaker doesn't send the
            // tutor's own voice straight back. Not available on every route;
            // carry on without it if it can't be enabled.
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                print("⚠️ Voice processing unavailable: \(error.localizedDescription)")
            }

            // Read the format only after voice processing is set — it can change it.
            let hardwareFormat = input.outputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
                  let converter = AVAudioConverter(from: hardwareFormat, to: engineFormat) else {
                throw AudioStreamError.microphoneUnavailable
            }

            // Touching the main mixer builds the output chain; per-peer
            // players are attached to it as peers start talking.
            _ = engine.mainMixerNode

            input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
                self?.handleCapturedBuffer(buffer, converter: converter)
            }

            engine.prepare()
            try engine.start()

            audioEngine = engine
            isCapturing = true
            lastEngineStart = Date()
            print("🎤 Audio capture and playback engine started")
        } catch {
            print("❌ Failed to start audio: \(error)")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
            Self.isVoiceSessionActive = false
            if !Self.isSessionHeldByCameraPiP {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            throw error
        }
    }

    private func teardownEngineLocked() {
        for player in peerPlayers.values { player.epoch += 1 }
        peerPlayers.removeAll()
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    /// Full rebuild: used when the hardware format may have changed.
    private func restartEngineLocked() {
        teardownEngineLocked()
        isCapturing = false
        do {
            try startEngineLocked()
            isInterrupted = false
            delegate?.audioStreamManager(self, didChangeRunning: true, message: nil)
        } catch {
            delegate?.audioStreamManager(self, didChangeRunning: false, message: "The microphone stopped and couldn't be restarted. Start the channel again.")
        }
    }

    // MARK: - Interruptions and route changes

    /// A phone call, Siri or an alarm stops the engine. Say so while it lasts
    /// and bring the engine back when the interruption ends.
    @objc private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        engineQueue.async {
            guard self.isCapturing else { return }
            switch type {
            case .began:
                self.isInterrupted = true
                self.delegate?.audioStreamManager(self, didChangeRunning: false, message: nil)
            case .ended:
                guard self.isInterrupted else { return }
                self.restartEngineLocked()
            @unknown default:
                break
            }
        }
    }

    /// The engine stops itself when the audio route or format changes
    /// (headphones plugged in, another feature changing the session).
    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        engineQueue.async {
            guard self.isCapturing, !self.isInterrupted, let engine = self.audioEngine,
                  (notification.object as? AVAudioEngine) === engine else { return }
            // Still running: nothing to do.
            guard !engine.isRunning else { return }
            // Starting the engine can itself post this notification; a plain
            // restart (not a rebuild) right after a start avoids a loop.
            if Date().timeIntervalSince(self.lastEngineStart) < 1 {
                do {
                    try engine.start()
                    self.lastEngineStart = Date()
                    self.resumePlayersLocked()
                } catch {
                    self.delegate?.audioStreamManager(self, didChangeRunning: false, message: "The microphone stopped and couldn't be restarted. Start the channel again.")
                }
            } else {
                self.restartEngineLocked()
            }
        }
    }

    private func resumePlayersLocked() {
        guard let engine = audioEngine, engine.isRunning else { return }
        for player in peerPlayers.values {
            player.epoch += 1
            player.queuedFrames = 0
            player.node.play()
        }
    }

    // MARK: - Processing

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        guard !isMuted, buffer.frameLength > 0 else { return }

        let ratio = engineFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: capacity) else { return }

        // Hand the captured buffer to the converter exactly once. Returning it
        // every time the converter asked duplicated audio whenever the buffer
        // sizes didn't line up.
        var hasSuppliedInput = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasSuppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasSuppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status != .error, error == nil, outputBuffer.frameLength > 0 {
            processAndSend(outputBuffer)
        }
    }

    private func processAndSend(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Calculate audio level (RMS)
        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        // Normalize to roughly 0.0 - 1.0 for UI (adjust sensitivity as needed)
        let normalizedLevel = min(1.0, rms * 5.0)
        delegate?.audioStreamManager(self, didUpdateLocalAudioLevel: normalizedLevel)

        // Convert Float32 to Int16 to reduce data size by 2x
        var int16Data = Data(capacity: frameCount * 2)
        for i in 0..<frameCount {
            let sample = channelData[i]
            // Clamp and convert
            let clampedSample = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clampedSample * Float(Int16.max))
            withUnsafeBytes(of: int16Sample) { int16Data.append(contentsOf: $0) }
        }

        delegate?.audioStreamManager(self, didCaptureAudioData: int16Data)
    }

    // MARK: - Playback Received Data

    /// Play received audio from one peer on that peer's own player.
    func playReceivedData(_ data: Data, fromPeer peerID: String) {
        // Convert Int16 Data back to Float32 AVAudioPCMBuffer
        let frameCount = data.count / 2
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        var sum: Float = 0
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            for i in 0..<frameCount {
                // loadUnaligned: the Data's bytes aren't guaranteed to be 2-byte aligned.
                let value = ptr.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                let sample = Float(value) / Float(Int16.max)
                channelData[i] = sample
                sum += sample * sample
            }
        }

        let rms = sqrt(sum / Float(frameCount))
        let normalizedLevel = min(1.0, rms * 5.0)

        engineQueue.async {
            guard self.isCapturing, !self.isInterrupted,
                  let engine = self.audioEngine, engine.isRunning else { return }

            let player: PeerPlayer
            if let existing = self.peerPlayers[peerID] {
                player = existing
            } else {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: self.engineFormat)
                node.play()
                player = PeerPlayer(node: node)
                self.peerPlayers[peerID] = player
            }

            // Too far behind (network burst, stall): drop the backlog and
            // play from the newest packet instead of letting delay grow.
            if player.queuedFrames + frameCount > self.maxQueuedFramesPerPeer {
                player.epoch += 1
                player.queuedFrames = 0
                player.node.stop()
                player.node.play()
            }

            let epoch = player.epoch
            player.queuedFrames += frameCount
            player.node.scheduleBuffer(buffer) { [weak self, weak player] in
                self?.engineQueue.async {
                    guard let player, player.epoch == epoch else { return }
                    player.queuedFrames = max(0, player.queuedFrames - frameCount)
                }
            }

            self.delegate?.audioStreamManager(self, didUpdateRemoteAudioLevel: normalizedLevel, forPeer: peerID)
        }
    }
}
