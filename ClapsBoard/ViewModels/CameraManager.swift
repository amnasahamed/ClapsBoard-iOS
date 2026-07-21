//
//  CameraManager.swift
//  ClapsBoard
//
//  Manages camera functionality with TRUE Picture-in-Picture support
//  Similar to Google Meet and Zoom - PiP works when leaving the app
//
//  App Store Checklist Items Addressed:
//  - ☐ Recording requires consent & indicators [Line 85]
//  - ☐ Secure data handling implemented - Camera is live preview only, never stored
//  - ☐ No unauthorized data access
//

import SwiftUI
import AVFoundation
import AVKit
import QuartzCore
import Combine
import UIKit

/// Off-screen host for the PiP sample-buffer layer.
/// Kept at the PiP render size (not the small widget size) so video fills the PiP window.
private final class PiPSourceHostView: UIView {
    weak var sampleBufferLayer: AVSampleBufferDisplayLayer?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .black
        alpha = 0.01
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let sampleLayer = sampleBufferLayer else { return }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleLayer.frame = bounds
        sampleLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        CATransaction.commit()
    }
}

/// Camera access and authorization status
enum CameraAuthorizationStatus {
    case authorized
    case denied
    case notDetermined
    case restricted
    
    var description: String {
        switch self {
        case .authorized: return "Camera access granted"
        case .denied: return "Camera access denied. Please enable in Settings."
        case .notDetermined: return "Camera permission not yet requested"
        case .restricted: return "Camera access is restricted on this device"
        }
    }
}

// MARK: - Camera Manager with Sample-Buffer PiP Support
/// Camera manager with Picture-in-Picture via AVSampleBufferDisplayLayer.
/// Uses the `audio` background mode + silent audio to keep PiP alive — no `voip` needed.
class CameraManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isActive: Bool = false
    @Published var isFlipped: Bool = true {
        didSet {
            updateVideoOrientationAndMirroring()
        }
    }
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    @Published var position: CGPoint = CGPoint(x: 20, y: 100)
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var authorizationStatus: CameraAuthorizationStatus = .notDetermined
    @Published var showPermissionAlert: Bool = false
    
    // MARK: - Private Properties
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    
    // PiP Components — sample-buffer approach (works with `audio` background mode only)
    private var pipController: AVPictureInPictureController?
    private var pipSampleBufferLayer: AVSampleBufferDisplayLayer?
    private var pipSourceHostView: PiPSourceHostView?
    private var pipHostSize = CGSize(width: 240, height: 318)
    private var pipTargetAspectRatio: CGFloat = 140.0 / 186.0
    
    // Sample buffer layer - exposed for direct display in CameraPreviewView
    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer? {
        return pipSampleBufferLayer ?? _legacySampleBufferLayer
    }
    private var _legacySampleBufferLayer: AVSampleBufferDisplayLayer?
    
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private let videoDataOutputQueue = DispatchQueue(label: "com.clapsboard.videoDataOutput", qos: .userInteractive)
    
    // Latest-frame buffer for PiP sample layer — avoids dropping frames when layer isn't ready
    private var latestSampleBuffer: CMSampleBuffer?
    private let sampleBufferLock = NSLock()
    private var isSampleBufferDisplayScheduled = false
    
    // Session state synchronization to prevent race conditions
    private let sessionLock = NSLock()
    private var isSettingUpSession: Bool = false
    private var isStoppingSession: Bool = false
    
    // Lifecycle tracking
    private var shouldAutoPiP: Bool = false // Auto-start PiP when backgrounding
    private var wasActiveBeforeBackground: Bool = false
    private var isPiPDisplayLayerAttached = false
    private var hasEnqueuedPiPFrame = false
    private var pipStartRetryCount = 0
    private let maxPiPStartRetries = 20
    
    // Watchdog: detects silent session stalls and restarts the feed
    private var sessionHealthTimer: Timer?
    private var lastFrameTimestamp: CFTimeInterval = 0
    
    // Silent audio keeps PiP + camera alive when the app is backgrounded (`audio` mode)
    private var silentAudioEngine: AVAudioEngine?
    private var isBackgroundKeepAliveActive = false
    
    
    var widgetSize: CGSize = CGSize(width: 140, height: 186)
    
    /// Matches the in-app widget aspect ratio at a larger size for PiP rendering.
    private var defaultPiPHostSize: CGSize {
        let aspect = widgetSize.height / widgetSize.width
        return CGSize(width: 240, height: 240 * aspect)
    }
    
    private func syncPiPTargetAspectRatio(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        pipHostSize = size
        pipTargetAspectRatio = size.width / size.height
    }
    
    override init() {
        super.init()
        updateAuthorizationStatus()
        setupAudioSession() // Required for PiP
        checkPiPSupport()
        setupNotificationObservers() // Monitor app lifecycle for PiP
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Audio Session Setup
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            print("✅ Audio session configured for video chat")
        } catch {
            print("⚠️ Failed to setup audio session: \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .videoChat, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
                    try session.setActive(true)
                } catch {
                    print("❌ Audio session retry also failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Playback-oriented session required for background PiP with the `audio` background mode.
    private func setupPiPAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            print("✅ Audio session configured for background PiP")
        } catch {
            print("⚠️ Failed to setup PiP audio session: \(error.localizedDescription)")
        }
    }
    
    /// Plays silent audio so iOS keeps the app alive for PiP while backgrounded.
    private func startBackgroundKeepAlive() {
        guard !isBackgroundKeepAliveActive else { return }
        
        setupPiPAudioSession()
        
        let engine = AVAudioEngine()
        let format = engine.outputNode.outputFormat(forBus: 0)
        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
        
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.001
        
        do {
            try engine.start()
            silentAudioEngine = engine
            isBackgroundKeepAliveActive = true
            print("🔇 Background keep-alive started (silent audio + PiP session)")
        } catch {
            print("❌ Failed to start background keep-alive: \(error.localizedDescription)")
        }
    }
    
    private func stopBackgroundKeepAlive() {
        guard isBackgroundKeepAliveActive else { return }
        silentAudioEngine?.stop()
        silentAudioEngine = nil
        isBackgroundKeepAliveActive = false
        setupAudioSession()
        print("🔇 Background keep-alive stopped")
    }
    
    /// Starts silent audio + ensures capture keeps running while PiP is backgrounded.
    private func activatePiPBackgroundMode() {
        startBackgroundKeepAlive()
        ensureSessionRunning(reason: "PiP background mode")
        recoverSampleBufferLayerIfNeeded()
    }
    
    // MARK: - PiP Support Check
    private func checkPiPSupport() {
        // Check if PiP is supported on this device
        isPiPPossible = AVPictureInPictureController.isPictureInPictureSupported()
        print("📺 PiP supported: \(isPiPPossible)")
    }
    
    // MARK: - Notification Observers
    /// Sets up observers for app lifecycle events to handle PiP automatically
    private func setupNotificationObservers() {
        // When app goes to background, auto-start PiP if camera is active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSceneWillResignActive),
            name: UIScene.willDeactivateNotification,
            object: nil
        )
        
        // When app returns to foreground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSceneDidBecomeActive),
            name: UIScene.didActivateNotification,
            object: nil
        )
        
        // Handle app entering background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Monitor capture session interruptions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureSessionInterrupted),
            name: AVCaptureSession.wasInterruptedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureSessionInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureSessionRuntimeError),
            name: AVCaptureSession.runtimeErrorNotification,
            object: nil
        )

        // Keep the camera feed upright when the device rotates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceOrientationChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleDeviceOrientationChange() {
        DispatchQueue.main.async { [weak self] in
            self?.updateVideoOrientationAndMirroring()
        }
    }
    
    @objc private func handleCaptureSessionInterrupted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else { return }
        
        print("🎥 Camera session interrupted: \(Self.interruptionReasonDescription(reason))")
        
        // Keep the watchdog running while PiP is active so we recover as soon as iOS allows.
        if !isPiPActive && !isBackgroundKeepAliveActive {
            stopSessionHealthMonitoring()
        } else {
            print("📺 PiP background mode active — waiting for interruption to end")
        }
    }
    
    private static func interruptionReasonDescription(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return "camera unavailable in background (needs multitasking-camera entitlement)"
        case .audioDeviceInUseByAnotherClient:
            return "microphone in use by another app"
        case .videoDeviceInUseByAnotherClient:
            return "camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "camera unavailable with multiple foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "camera unavailable due to system pressure"
        case .sensitiveContentMitigationActivated:
            return "camera paused due to sensitive content mitigation"
        @unknown default:
            return "unknown (\(reason.rawValue))"
        }
    }
    
    @objc private func handleCaptureSessionInterruptionEnded(_ notification: Notification) {
        print("🎥 Camera session interruption ended - resuming...")
        ensureSessionRunning(reason: "interruption ended")
    }
    
    @objc private func handleCaptureSessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        print("🎥 Camera session runtime error: \(error.localizedDescription) (code: \(error.code.rawValue))")
        ensureSessionRunning(reason: "runtime error recovery")
    }
    
    @objc private func handleSceneWillResignActive(_ notification: Notification) {
        // Prepare background PiP *before* iOS suspends the capture session.
        if isPiPActive {
            print("📱 Scene deactivating with PiP active — enabling background keep-alive")
            activatePiPBackgroundMode()
        } else if isActive {
            print("📱 App resigning active - enabling auto-PiP intent")
            shouldAutoPiP = true
        }
    }
    
    @objc private func handleSceneDidBecomeActive(_ notification: Notification) {
        print("📱 App became active")
        ensureSessionRunning(reason: "scene became active")
        recoverSampleBufferLayerIfNeeded()
    }
    
    @objc private func handleAppDidEnterBackground(_ notification: Notification) {
        wasActiveBeforeBackground = isActive
        print("📱 App entered background - camera active: \(isActive), PiP active: \(isPiPActive)")
        
        if isPiPActive || (isActive && shouldAutoPiP) {
            activatePiPBackgroundMode()
        }
    }
    
    @objc private func handleAppWillEnterForeground(_ notification: Notification) {
        print("📱 App entering foreground - was active: \(wasActiveBeforeBackground)")
        stopBackgroundKeepAlive()
        ensureSessionRunning(reason: "entering foreground")
        recoverSampleBufferLayerIfNeeded()
    }
    
    // MARK: - Session Health
    
    /// Restarts the capture session when it silently stops while the camera should be active.
    private func ensureSessionRunning(reason: String) {
        guard isActive, !isStoppingSession, !isSettingUpSession else { return }
        guard let session = captureSession else { return }
        
        if !session.isRunning {
            print("🔄 Restarting camera session (\(reason))")
            if isPiPActive || isBackgroundKeepAliveActive {
                setupPiPAudioSession()
            } else {
                setupAudioSession()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                DispatchQueue.main.async { [weak self] in
                    self?.updateVideoOrientationAndMirroring()
                    self?.recoverSampleBufferLayerIfNeeded()
                }
            }
        }
    }
    
    private func startSessionHealthMonitoring() {
        stopSessionHealthMonitoring()
        lastFrameTimestamp = CACurrentMediaTime()
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessionHealthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.performSessionHealthCheck()
            }
        }
    }
    
    private func stopSessionHealthMonitoring() {
        DispatchQueue.main.async { [weak self] in
            self?.sessionHealthTimer?.invalidate()
            self?.sessionHealthTimer = nil
        }
    }
    
    private func performSessionHealthCheck() {
        guard isActive, !isStoppingSession else { return }
        
        let now = CACurrentMediaTime()
        let secondsSinceLastFrame = now - lastFrameTimestamp
        
        // No frames for 3+ seconds while camera is "on" → session likely stalled
        if secondsSinceLastFrame > 3.0 {
            print("⚠️ Camera feed stalled (\(String(format: "%.1f", secondsSinceLastFrame))s since last frame)")
            ensureSessionRunning(reason: "health check — no frames")
            recoverSampleBufferLayerIfNeeded()
            lastFrameTimestamp = now
        } else if captureSession?.isRunning == false {
            ensureSessionRunning(reason: "health check — session not running")
        }
    }
    
    /// Flushes and re-primes the sample buffer display layer when it enters a failed state.
    private func recoverSampleBufferLayerIfNeeded() {
        videoDataOutputQueue.async { [weak self] in
            guard let self, let layer = self.sampleBufferDisplayLayer else { return }
            
            if layer.status == .failed {
                print("🔄 Recovering failed sample buffer layer: \(layer.error?.localizedDescription ?? "unknown")")
                layer.flush()
            }
            
            self.isSampleBufferDisplayScheduled = false
            self.scheduleSampleBufferDisplayIfNeeded()
        }
    }
    
    // MARK: - Permission Handling
    /// Updates the current authorization status
    private func updateAuthorizationStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationStatus = .authorized
        case .denied:
            authorizationStatus = .denied
        case .notDetermined:
            authorizationStatus = .notDetermined
        case .restricted:
            authorizationStatus = .restricted
        @unknown default:
            authorizationStatus = .denied
        }
    }
    
    /// Requests camera permission with proper consent flow
    /// NOTE: iOS shows the system camera indicator (green dot) when camera is active
    func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationStatus = .authorized
            completion(true)
            
        case .notDetermined:
            // Request permission - iOS will show the permission dialog
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationStatus = granted ? .authorized : .denied
                    completion(granted)
                }
            }
            
        case .denied, .restricted:
            authorizationStatus = .denied
            showPermissionAlert = true
            completion(false)
            
        @unknown default:
            authorizationStatus = .denied
            completion(false)
        }
    }
    
    /// Opens iOS Settings for the user to change camera permission
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    
    // MARK: - Camera Control
    
    /// Starts the camera with permission check and PiP setup
    /// NOTE: This is a LIVE PREVIEW ONLY feature - video is NEVER recorded or stored
    func startCamera() {
        // Prevent race conditions with session state lock
        sessionLock.lock()
        defer { sessionLock.unlock() }
        
        // Check if already running or in the process of setting up/stopping
        guard captureSession == nil, !isSettingUpSession, !isStoppingSession else { return }
        isSettingUpSession = true
        
        // Verify permission first
        requestCameraPermission { [weak self] granted in
            guard let self = self, granted else {
                self?.sessionLock.lock()
                self?.isSettingUpSession = false
                self?.sessionLock.unlock()
                return
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                self.setupCaptureSession()
                DispatchQueue.main.async {
                    self.sessionLock.lock()
                    self.isSettingUpSession = false
                    self.sessionLock.unlock()
                }
            }
        }
    }
    
    /// Stops the camera and releases resources
    func stopCamera() {
        // Prevent race conditions with session state lock
        sessionLock.lock()
        
        // Check if already stopping or nothing to stop
        guard !isStoppingSession else {
            sessionLock.unlock()
            return
        }
        isStoppingSession = true
        sessionLock.unlock()
        
        // Stop PiP first
        if isPiPActive {
            stopPiP()
        }
        
        // Capture references before clearing
        let session = captureSession
        let sampleLayer = sampleBufferDisplayLayer
        
        // Clear references immediately to prevent new operations
        captureSession = nil
        previewLayer = nil
        pipController = nil
        pipSampleBufferLayer = nil
        _legacySampleBufferLayer = nil
        videoDataOutput = nil
        detachPiPSourceHostView()
        isPiPDisplayLayerAttached = false
        hasEnqueuedPiPFrame = false
        pipStartRetryCount = 0
        SampleBufferProcessor.resetPool()
        SampleBufferProcessor.resetDiagnostics()
        
        sampleBufferLock.lock()
        latestSampleBuffer = nil
        isSampleBufferDisplayScheduled = false
        sampleBufferLock.unlock()
        
        stopSessionHealthMonitoring()
        DispatchQueue.main.async {
            self.isActive = false
            self.isPiPActive = false
        }
        
        // HIG: stopRunning() is a blocking call, move to background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Flush sample buffer layer before stopping session to prevent frame queuing errors
            sampleLayer?.flush()
            session?.stopRunning()
            
            DispatchQueue.main.async {
                self?.sessionLock.lock()
                self?.isStoppingSession = false
                self?.sessionLock.unlock()
            }
        }
    }
    
    /// Sets up the capture session for live preview with PiP support
    private func setupCaptureSession() {
        let session = AVCaptureSession()
        session.sessionPreset = .high // Higher quality for PiP
        
        // Enable multitasking camera access for background PiP (iOS 16+, requires entitlement)
        if #available(iOS 16.0, *) {
            if session.isMultitaskingCameraAccessSupported {
                session.isMultitaskingCameraAccessEnabled = true
                print("✅ Multitasking camera access enabled")
            } else {
                print("⚠️ Multitasking camera access not supported (Simulator lacks it; physical device needs com.apple.developer.avfoundation.multitasking-camera-access entitlement)")
            }
        }
        
        // Setup front camera for selfie/mirror mode
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            DispatchQueue.main.async {
                self.authorizationStatus = .restricted
            }
            return
        }
        
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            print("❌ Failed to create camera input: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.authorizationStatus = .denied
            }
            return
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        // Setup video data output for PiP sample buffer
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        dataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        dataOutput.alwaysDiscardsLateVideoFrames = true
        
        if session.canAddOutput(dataOutput) {
            session.addOutput(dataOutput)
        }
        videoDataOutput = dataOutput
        
        // Configure video connection for proper orientation.
        // Note: interface orientation must be read on the main thread; the
        // orientation is re-synced in updateVideoOrientationAndMirroring()
        // once setup completes on the main queue below.
        if let connection = dataOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isFlipped
            }
        }
        
        // Setup preview layer (for fallback display)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        
        // Start session - iOS will show the camera indicator (green dot)
        session.startRunning()
        
        DispatchQueue.main.async {
            self.captureSession = session
            self.previewLayer = layer
            self.isActive = true
            
            // Setup PiP components after session is running
            if #available(iOS 15.0, *) {
                self.setupPiPVideoCallController()
            } else {
                self.setupLegacySampleBufferLayer()
            }
            self.updateVideoOrientationAndMirroring()
            self.startSessionHealthMonitoring()
        }
    }
    
    /// Sets up legacy sample buffer layer for iOS < 15
    private func setupLegacySampleBufferLayer() {
        let sampleLayer = AVSampleBufferDisplayLayer()
        sampleLayer.videoGravity = .resizeAspectFill
        sampleLayer.frame = CGRect(x: 0, y: 0, width: 160, height: 213)
        _legacySampleBufferLayer = sampleLayer
        print("📺 Legacy sample buffer layer created (no PiP support)")
    }
    
    /// Sets up PiP using the sample-buffer approach.
    /// This works with the `audio` background mode — no `voip` entitlement needed.
    /// Silent audio keeps the PiP window alive when the app is backgrounded.
    @available(iOS 15.0, *)
    private func setupPiPVideoCallController() {
        guard isPiPPossible else {
            print("⚠️ PiP not supported on this device")
            return
        }
        
        let sampleLayer = AVSampleBufferDisplayLayer()
        sampleLayer.videoGravity = .resizeAspectFill
        sampleLayer.preventsCapture = false
        pipSampleBufferLayer = sampleLayer
        syncPiPTargetAspectRatio(to: defaultPiPHostSize)
        
        print("📺 PiP sample buffer layer created — waiting for PiP host view...")
        DispatchQueue.main.async { [weak self] in
            self?.attachPiPSourceHostViewIfNeeded()
        }
    }
    
    private static var activeKeyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }?
            .keyWindow
    }
    
    private func pipHostFrame(for size: CGSize) -> CGRect {
        // Off-screen but still in the window hierarchy (required for sample-buffer PiP).
        CGRect(x: -size.width - 24, y: 0, width: size.width, height: size.height)
    }
    
    private func attachPiPSourceHostViewIfNeeded() {
        guard pipSourceHostView == nil else {
            layoutPiPSampleBufferLayerInHost()
            return
        }
        
        guard let window = Self.activeKeyWindow else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.attachPiPSourceHostViewIfNeeded()
            }
            return
        }
        
        let host = PiPSourceHostView(frame: pipHostFrame(for: pipHostSize))
        window.addSubview(host)
        pipSourceHostView = host
        layoutPiPSampleBufferLayerInHost()
        
        isPiPDisplayLayerAttached = true
        print("📺 PiP source host attached (\(Int(pipHostSize.width))x\(Int(pipHostSize.height)))")
        if #available(iOS 15.0, *) {
            attemptPiPControllerSetupIfReady()
        }
    }
    
    private func layoutPiPSampleBufferLayerInHost() {
        guard let host = pipSourceHostView, let sampleLayer = pipSampleBufferLayer else { return }
        
        if sampleLayer.superlayer !== host.layer {
            sampleLayer.removeFromSuperlayer()
            host.layer.addSublayer(sampleLayer)
        }
        
        host.sampleBufferLayer = sampleLayer
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleLayer.frame = host.bounds
        sampleLayer.bounds = CGRect(origin: .zero, size: host.bounds.size)
        sampleLayer.videoGravity = .resizeAspectFill
        CATransaction.commit()
    }
    
    private func detachPiPSourceHostView() {
        pipSampleBufferLayer?.removeFromSuperlayer()
        pipSourceHostView?.removeFromSuperview()
        pipSourceHostView = nil
    }
    
    private func updatePiPHostRenderSize(_ renderSize: CMVideoDimensions) {
        let size = CGSize(width: CGFloat(renderSize.width), height: CGFloat(renderSize.height))
        guard size.width > 0, size.height > 0 else { return }
        
        syncPiPTargetAspectRatio(to: size)
        pipSourceHostView?.frame = pipHostFrame(for: size)
        layoutPiPSampleBufferLayerInHost()
        
        pipSampleBufferLayer?.flush()
        hasEnqueuedPiPFrame = false
        SampleBufferProcessor.resetPool()
        SampleBufferProcessor.resetDiagnostics()
        
        print("📺 PiP host resized to match render size: \(Int(size.width))x\(Int(size.height))")
    }
    
    /// PiP requires the sample buffer layer to be in a window and receiving frames.
    @available(iOS 15.0, *)
    private func attemptPiPControllerSetupIfReady() {
        guard isPiPPossible, pipController == nil, let sampleLayer = pipSampleBufferLayer else { return }
        guard isPiPDisplayLayerAttached, sampleLayer.superlayer != nil else {
            print("⚠️ PiP setup waiting: layer attached=\(isPiPDisplayLayerAttached), in hierarchy=\(sampleLayer.superlayer != nil)")
            return
        }
        setupPiPController()
    }
    
    /// Sets up AVPictureInPictureController with sample buffer content source.
    @available(iOS 15.0, *)
    private func setupPiPController() {
        guard isPiPPossible,
              let sampleLayer = pipSampleBufferLayer else {
            print("⚠️ PiP setup failed: sampleLayer=\(pipSampleBufferLayer != nil)")
            return
        }
        
        guard sampleLayer.superlayer != nil else {
            print("⚠️ PiP setup deferred: sample buffer layer not in view hierarchy")
            return
        }
        
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleLayer,
            playbackDelegate: self
        )
        
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        
        pipController = controller
        
        print("✅ PiP Controller setup with Sample Buffer approach")
        
        if shouldAutoPiP {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startPiP()
            }
        }
    }
    
    private func markPiPFrameEnqueuedIfNeeded() {
        guard !hasEnqueuedPiPFrame else { return }
        hasEnqueuedPiPFrame = true
        if #available(iOS 15.0, *) {
            DispatchQueue.main.async { [weak self] in
                self?.attemptPiPControllerSetupIfReady()
                if self?.shouldAutoPiP == true {
                    self?.startPiP()
                }
            }
        }
    }
    
    /// Updates orientation and mirroring on capture connections and the preview layer.
    private func updateVideoOrientationAndMirroring() {
        let orientation = currentVideoOrientation

        if let connection = videoDataOutput?.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isFlipped
            }
        }

        if let previewConnection = previewLayer?.connection {
            if previewConnection.isVideoOrientationSupported {
                previewConnection.videoOrientation = orientation
            }
            if previewConnection.isVideoMirroringSupported {
                previewConnection.automaticallyAdjustsVideoMirroring = false
                previewConnection.isVideoMirrored = isFlipped
            }
        }
    }

    /// Maps the active scene's interface orientation to a capture orientation
    private var currentVideoOrientation: AVCaptureVideoOrientation {
        let interfaceOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .interfaceOrientation ?? .portrait

        switch interfaceOrientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
    
    // MARK: - Camera Actions
    
    /// Toggles camera on/off
    func toggleCamera() {
        if isActive {
            stopCamera()
        } else {
            startCamera()
        }
    }
    
    /// Toggles horizontal flip/mirror
    func toggleFlip() {
        isFlipped.toggle()
    }
    
    /// Toggles TRUE iOS Picture‑in‑Picture mode (works when leaving the app)
    func togglePiP() {
        print("🔘 PiP button tapped!")
        print("   - Camera active: \(isActive)")
        print("   - PiP active: \(isPiPActive)")
        print("   - PiP supported: \(isPiPPossible)")
        print("   - PiP controller exists: \(pipController != nil)")
        print("   - Sample buffer layer exists: \(sampleBufferDisplayLayer != nil)")
        print("   - PiP sample layer exists: \(pipSampleBufferLayer != nil)")
        print("   - PiP layer in hierarchy: \(pipSampleBufferLayer?.superlayer != nil)")
        print("   - PiP layer attached to window: \(isPiPDisplayLayerAttached)")
        print("   - PiP frames enqueued: \(hasEnqueuedPiPFrame)")
        print("   - PiP start possible now: \(pipController?.isPictureInPicturePossible ?? false)")
        
        if !isActive {
            print("   → Camera not active, starting camera first...")
            shouldAutoPiP = true
            startCamera()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.startPiP()
            }
            return
        }

        // Ensure we have a valid controller before proceeding.
        guard pipController != nil else {
            print("⚠️ PiP controller not ready – attempting setup again.")
            if #available(iOS 15.0, *) {
                setupPiPController()
            }
            shouldAutoPiP = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startPiP()
            }
            return
        }
        
        if isPiPActive {
            print("   → PiP is active, stopping...")
            shouldAutoPiP = false
            stopPiP()
        } else {
            print("   → PiP is not active, starting...")
            shouldAutoPiP = true
            pipStartRetryCount = 0
            startPiP()
        }
    }
    
    /// Starts Picture‑in‑Picture
    func startPiP() {
        if #available(iOS 15.0, *) {
            attemptPiPControllerSetupIfReady()
        }
        
        guard let controller = pipController else {
            guard pipStartRetryCount < maxPiPStartRetries else {
                print("❌ PiP controller not available after \(maxPiPStartRetries) retries")
                shouldAutoPiP = false
                return
            }
            pipStartRetryCount += 1
            print("⚠️ PiP controller not available – retry \(pipStartRetryCount)/\(maxPiPStartRetries)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startPiP()
            }
            return
        }
        
        if controller.isPictureInPictureActive {
            print("✅ PiP already active")
            pipStartRetryCount = 0
            return
        }
        
        // Switch to playback audio session + silent audio so PiP stays alive in background
        startBackgroundKeepAlive()
        
        if controller.isPictureInPicturePossible {
            print("🎬 Starting PiP...")
            pipStartRetryCount = 0
            controller.startPictureInPicture()
        } else {
            guard pipStartRetryCount < maxPiPStartRetries else {
                let layerStatus = pipSampleBufferLayer.map { String(describing: $0.status) } ?? "nil"
                print("❌ PiP not possible after \(maxPiPStartRetries) retries (layer status: \(layerStatus), in hierarchy: \(pipSampleBufferLayer?.superlayer != nil), frames enqueued: \(hasEnqueuedPiPFrame))")
                shouldAutoPiP = false
                return
            }
            pipStartRetryCount += 1
            print("⚠️ PiP not possible yet – retry \(pipStartRetryCount)/\(maxPiPStartRetries)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startPiP()
            }
        }
    }
    
    /// Stops Picture-in-Picture
    func stopPiP() {
        shouldAutoPiP = false
        pipStartRetryCount = 0
        stopBackgroundKeepAlive()
        
        guard let controller = pipController else {
            DispatchQueue.main.async {
                self.isPiPActive = false
            }
            return
        }
        
        if controller.isPictureInPictureActive {
            print("⏹️ Stopping PiP...")
            controller.stopPictureInPicture()
        }
        
        DispatchQueue.main.async {
            self.isPiPActive = false
        }
    }
    
    // MARK: - Drag Position
    
    /// Updates the camera widget position, keeping it within bounds
    func updatePosition(to point: CGPoint, in bounds: CGRect) {
        // Ensure widget stays within screen bounds
        let maxX = bounds.width - widgetSize.width
        let maxY = bounds.height - widgetSize.height
        
        position = CGPoint(
            x: min(max(point.x, 0), maxX),
            y: min(max(point.y, 0), maxY)
        )
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isStoppingSession else { return }
        
        lastFrameTimestamp = CACurrentMediaTime()
        
        // Keep latest frame for PiP sample buffer layer
        sampleBufferLock.lock()
        latestSampleBuffer = sampleBuffer
        sampleBufferLock.unlock()
        
        scheduleSampleBufferDisplayIfNeeded()
    }
    
    /// Delivers the latest camera frame to the PiP sample buffer layer using Apple's
    /// requestMediaDataWhenReady pattern — prevents the layer from freezing when it
    /// temporarily can't accept frames.
    private func scheduleSampleBufferDisplayIfNeeded() {
        guard !isStoppingSession, sampleBufferDisplayLayer != nil else { return }
        
        sampleBufferLock.lock()
        let alreadyScheduled = isSampleBufferDisplayScheduled
        if !alreadyScheduled {
            isSampleBufferDisplayScheduled = true
        }
        sampleBufferLock.unlock()
        
        guard !alreadyScheduled else { return }
        
        guard let sampleLayer = sampleBufferDisplayLayer else {
            sampleBufferLock.lock()
            isSampleBufferDisplayScheduled = false
            sampleBufferLock.unlock()
            return
        }
        
        sampleLayer.requestMediaDataWhenReady(on: videoDataOutputQueue) { [weak self] in
            guard let self, !self.isStoppingSession else { return }
            guard let layer = self.sampleBufferDisplayLayer else {
                self.sampleBufferLock.lock()
                self.isSampleBufferDisplayScheduled = false
                self.sampleBufferLock.unlock()
                return
            }
            
            if layer.status == .failed {
                layer.flush()
            }
            
            while layer.isReadyForMoreMediaData {
                self.sampleBufferLock.lock()
                guard let buffer = self.latestSampleBuffer else {
                    self.isSampleBufferDisplayScheduled = false
                    self.sampleBufferLock.unlock()
                    return
                }
                self.sampleBufferLock.unlock()
                
                let croppedBuffer = SampleBufferProcessor.centerCropped(
                    buffer,
                    toAspectRatio: self.pipTargetAspectRatio
                ) ?? buffer
                layer.enqueue(croppedBuffer)
                self.markPiPFrameEnqueuedIfNeeded()
                break // Live feed: one frame per ready cycle keeps latency low
            }
            
            self.sampleBufferLock.lock()
            let hasPendingFrame = self.latestSampleBuffer != nil
            if !layer.isReadyForMoreMediaData && hasPendingFrame {
                self.isSampleBufferDisplayScheduled = false
                self.sampleBufferLock.unlock()
                self.scheduleSampleBufferDisplayIfNeeded()
            } else {
                self.isSampleBufferDisplayScheduled = false
                self.sampleBufferLock.unlock()
            }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension CameraManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎬 PiP will start")
        activatePiPBackgroundMode()
        DispatchQueue.main.async {
            self.isPiPActive = true
        }
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ PiP did start - camera now works outside the app!")
        activatePiPBackgroundMode()
        ensureSessionRunning(reason: "PiP did start")
        recoverSampleBufferLayerIfNeeded()
        DispatchQueue.main.async {
            self.isPiPActive = true
        }
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("⏹️ PiP will stop")
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ PiP did stop - returning to inline mode")
        DispatchQueue.main.async {
            self.isPiPActive = false
            // Don't auto-restart PiP after manual stop
            self.shouldAutoPiP = false
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("❌ PiP failed to start: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isPiPActive = false
            self.shouldAutoPiP = false
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // Restore the app's UI when PiP is stopped by tapping on it
        print("🔄 Restoring UI from PiP - user tapped the PiP window")
        
        // Ensure camera session is running
        if let session = captureSession, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }
        
        // Notify that restoration is complete
        // Use CATransaction to ensure all UI updates are committed before completion
        // This prevents "deleted thread with uncommitted CATransaction" warning
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                completionHandler(true)
            }
            self.isPiPActive = false
            CATransaction.commit()
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
@available(iOS 15.0, *)
extension CameraManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // For live camera, we're always "playing"
        // This delegate method is called when user taps play/pause in PiP
        print("🎮 PiP playback state changed to: \(playing ? "playing" : "paused")")
        
        if playing {
            startBackgroundKeepAlive()
            ensureSessionRunning(reason: "PiP setPlaying(true)")
        } else {
            print("⏸️ User paused PiP (camera continues in background)")
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Return an infinite time range for live content
        // This tells iOS that this is a live stream with no beginning or end
        return CMTimeRange(start: .negativeInfinity, end: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // Live camera is never paused - always return false to indicate active stream
        let isRunning = captureSession?.isRunning ?? false
        return !isRunning
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("📐 PiP render size changed to: \(newRenderSize.width)x\(newRenderSize.height)")
        DispatchQueue.main.async { [weak self] in
            self?.updatePiPHostRenderSize(newRenderSize)
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        // Not applicable for live camera - no seeking in live streams
        print("⏭️ Skip requested (not applicable for live camera)")
        completion()
    }
}

// MARK: - Camera Preview UIViewRepresentable
struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var cameraManager: CameraManager
    
    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.cameraManager = cameraManager
        view.setupObserver()
        return view
    }
    
    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // Called whenever SwiftUI observes changes in cameraManager
        uiView.updateLayers()
    }
}

// MARK: - Camera Preview UIView
/// Custom UIView that properly manages camera layers and registers as PiP source
class CameraPreviewUIView: UIView {
    weak var cameraManager: CameraManager?
    private var previewLayerAdded = false
    private var cancellables = Set<AnyCancellable>()
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        
        if window != nil {
            print("📺 Camera view added to window")
            DispatchQueue.main.async { [weak self] in
                self?.updateLayers()
            }
        }
    }
    
    func setupObserver() {
        guard let cameraManager = cameraManager else { return }
        
        // Observe previewLayer changes
        cameraManager.$previewLayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] layer in
                if layer != nil {
                    print("📺 Preview layer became available - updating view")
                    self?.updateLayers()
                }
            }
            .store(in: &cancellables)
        
        // Also observe isActive to refresh preview after session recovery
        cameraManager.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                if isActive {
                    self?.updateLayers()
                }
            }
            .store(in: &cancellables)
        
        // Also observe isFlipped changes
        cameraManager.$isFlipped
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayers()
            }
            .store(in: &cancellables)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updatePreviewLayerFrame()
    }
    
    private func updatePreviewLayerFrame() {
        guard let cameraManager = cameraManager,
              let previewLayer = cameraManager.previewLayer else { return }
        
        // Ensure bounds are valid
        guard bounds.width > 0 && bounds.height > 0 else { return }
        
        // Ensure the layer is in our hierarchy
        if previewLayer.superlayer != layer {
            // Remove any existing preview layers first
            layer.sublayers?.forEach { sublayer in
                if sublayer is AVCaptureVideoPreviewLayer {
                    sublayer.removeFromSuperlayer()
                }
            }
            layer.addSublayer(previewLayer)
            previewLayerAdded = true
            print("📺 Preview layer added to view hierarchy")
        }
        
        // Apply mirror via connection when supported; fall back to transform otherwise
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        
        if let connection = previewLayer.connection,
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = cameraManager.isFlipped
            previewLayer.transform = CATransform3DIdentity
        } else if cameraManager.isFlipped {
            previewLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        } else {
            previewLayer.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }
    
    func updateLayers() {
        setNeedsLayout()
        layoutIfNeeded()
    }
}

// MARK: - Camera Permission Denied View
struct CameraPermissionDeniedView: View {
    let onOpenSettings: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text("Camera Access Required")
                .font(.headline)
            
            Text("Please enable camera access in Settings to use the camera mirror feature.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
