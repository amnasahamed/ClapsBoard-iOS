//
//  AudioStreamManager.swift
//  ClapsBoard
//
//  Handles real-time audio capture and playback for VoIP voice channel
//  Optimized for peer-to-peer transmission
//

import Foundation
import AVFoundation

/// Delegate for audio stream events
protocol AudioStreamManagerDelegate: AnyObject {
    func audioStreamManager(_ manager: AudioStreamManager, didCaptureAudioData data: Data)
    func audioStreamManager(_ manager: AudioStreamManager, didUpdateLocalAudioLevel level: Float)
    func audioStreamManager(_ manager: AudioStreamManager, didUpdateRemoteAudioLevel level: Float)
}

/// Manages audio capture and playback for voice communication
class AudioStreamManager: NSObject {
    
    // MARK: - Properties
    weak var delegate: AudioStreamManagerDelegate?
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var playerNode: AVAudioPlayerNode?
    private var mixerNode: AVAudioMixerNode?
    
    private var isCapturing = false
    private var isMuted = false
    
    // Audio formats
    private let transmissionFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private let engineFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    
    private var inputConverter: AVAudioConverter?
    
    // MARK: - Capture
    
    /// Start capturing audio from microphone
    func startCapturing() {
        guard !isCapturing else { return }
        
        do {
            // Configure audio session
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
                .allowBluetoothA2DP,
                .defaultToSpeaker,
                .mixWithOthers
            ])
            try session.setActive(true)
            
            // Setup audio engine
            audioEngine = AVAudioEngine()
            guard let engine = audioEngine else { return }
            
            inputNode = engine.inputNode
            playerNode = AVAudioPlayerNode()
            mixerNode = AVAudioMixerNode()
            
            // Add nodes
            engine.attach(playerNode!)
            engine.attach(mixerNode!)
            
            // Get native hardware format
            let hardwareFormat = inputNode!.outputFormat(forBus: 0)
            
            // Setup input converter (Hardware -> engineFormat)
            inputConverter = AVAudioConverter(from: hardwareFormat, to: engineFormat)
            
            // Connect nodes for playback
            // Received audio (engineFormat) -> Playback
            engine.connect(playerNode!, to: mixerNode!, format: engineFormat)
            engine.connect(mixerNode!, to: engine.mainMixerNode, format: engineFormat)
            
            // Install tap on input for capturing
            inputNode!.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, time in
                self?.handleCapturedBuffer(buffer)
            }
            
            // Start engine
            engine.prepare()
            try engine.start()
            playerNode?.play()
            
            isCapturing = true
            print("🎤 Audio capture and playback engine started")
            
        } catch {
            print("❌ Failed to start audio: \(error)")
        }
    }
    
    /// Stop capturing and reset engine
    func stopCapturing() {
        guard isCapturing else { return }
        
        isCapturing = false
        
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        playerNode?.stop()
        
        audioEngine = nil
        inputNode = nil
        playerNode = nil
        mixerNode = nil
        inputConverter = nil
        
        print("🔇 Audio engine stopped and cleaned up")
    }
    
    /// Set mute state
    func setMuted(_ muted: Bool) {
        isMuted = muted
    }
    
    // MARK: - Processing
    
    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted, let converter = inputConverter else { return }
        
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: AVAudioFrameCount(engineFormat.sampleRate * 0.1))!
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        if status == .haveData {
            processAndSend(outputBuffer)
        }
    }
    
    private func processAndSend(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        
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
    
    /// Play received compressed audio data
    func playReceivedData(_ data: Data) {
        guard isCapturing, let playerNode = playerNode else { return }
        
        // Convert Int16 Data back to Float32 AVAudioPCMBuffer
        let frameCount = data.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        
        guard let channelData = buffer.floatChannelData?[0] else { return }
        
        var sum: Float = 0
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16Ptr = ptr.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let sample = Float(int16Ptr[i]) / Float(Int16.max)
                channelData[i] = sample
                sum += sample * sample
            }
        }
        
        let rms = sqrt(sum / Float(frameCount))
        let normalizedLevel = min(1.0, rms * 5.0)
        delegate?.audioStreamManager(self, didUpdateRemoteAudioLevel: normalizedLevel)
        
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }
}
