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
            saveWidgetPreferences()
        }
    }
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    @Published var position: CGPoint = CGPoint(x: 20, y: 100) { didSet { saveWidgetPreferences() } }
    @Published var isPositionLocked: Bool = false { didSet { saveWidgetPreferences() } }
    @Published var isCircular: Bool = false { didSet { updateWidgetSize(); saveWidgetPreferences() } }
    @Published var previewOpacity: Double = 1 { didSet { saveWidgetPreferences() } }
    @Published var widgetScale: CGFloat = 1 { didSet { updateWidgetSize(); saveWidgetPreferences() } }
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var authorizationStatus: CameraAuthorizationStatus = .notDetermined
    @Published var showPermissionAlert: Bool = false
    /// Short user-facing notice (camera or PiP could not start). Shown by
    /// CameraOverlay and cleared automatically after a few seconds.
    @Published var statusMessage: String?
    private var statusMessageClearWork: DispatchWorkItem?
    /// True while stored widget preferences are being read, so the property
    /// observers don't write the defaults back over values not yet loaded.
    private var isLoadingPreferences = false
    
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
    private let audioSessionQueue = DispatchQueue(label: "com.clapsboard.audioSession", qos: .userInitiated)
    
    // Latest-frame buffer for PiP sample layer — avoids dropping frames when layer isn't ready
    private var latestSampleBuffer: CMSampleBuffer?
    private let sampleBufferLock = NSLock()
    private var isSampleBufferDisplayScheduled = false
    
    // Session state synchronization to prevent race conditions
    private let sessionLock = NSLock()
    private var isSettingUpSession: Bool = false
    private var isStoppingSession: Bool = false
    /// Set when stopCamera() arrives while setup is still in flight.
    private var isStopPendingAfterSetup: Bool = false
    /// Set when startCamera() arrives while a stop is still in flight, so a
    /// quick off-then-on isn't dropped.
    private var isStartPendingAfterStop: Bool = false
    /// All startRunning/stopRunning calls go through one serial queue so a stop
    /// can never overtake the start it is meant to cancel.
    private let sessionQueue = DispatchQueue(label: "com.clapsboard.captureSession", qos: .userInitiated)
    
    // Lifecycle tracking
    private var shouldAutoPiP: Bool = false // Auto-start PiP when backgrounding
    private var wasActiveBeforeBackground: Bool = false
    private var isPiPDisplayLayerAttached = false
    private var hasEnqueuedPiPFrame = false
    private var pipStartRetryCount = 0
    private let maxPiPStartRetries = 20
    /// A start request is in flight; repeated requests are ignored until it lands.
    private var isPiPStartPending = false
    /// When PiP last began stopping. iOS briefly resigns the scene while the PiP
    /// window animates closed, and that must not read as "the tutor left the app".
    private var lastPiPStopDate: Date?
    private let pipStopSettleInterval: TimeInterval = 1.5
    /// Bumped whenever PiP is stopped or cancelled; delayed start retries
    /// carry the value they were scheduled with and give up if it has moved on.
    private var pipStartGeneration = 0
    /// PiP was requested by the scene deactivating (not by the PiP button).
    /// If the scene comes back without the app having gone to the background
    /// (Control Center, Notification Center, a system alert) it is undone.
    private var isPiPRequestedByDeactivation = false
    private var didEnterBackgroundSinceDeactivation = false
    /// A cancelled start was already handed to iOS; stop PiP as soon as it reports started.
    private var shouldStopPiPOnceStarted = false
    
    // iOS 17 rotation coordinator: gives the right angle for whichever camera
    // is in use (the hand-written table below was derived for the back camera).
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    
    // Watchdog: detects silent session stalls and restarts the feed
    private var sessionHealthTimer: Timer?
    private var lastFrameTimestamp: CFTimeInterval = 0
    
    // Silent audio keeps PiP + camera alive when the app is backgrounded (`audio` mode)
    private var silentAudioEngine: AVAudioEngine?
    private var isBackgroundKeepAliveActive = false
    private var isBackgroundKeepAliveStarting = false
    /// The keep-alive activated the audio session and it has not been released yet.
    private var keepAliveSessionNeedsRelease = false
    
    
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
        loadWidgetPreferences()
        updateAuthorizationStatus()
        // The audio session is deliberately not touched at launch: the camera
        // captures no audio. It is configured when the camera turns on (category
        // only) and activated only while the PiP keep-alive runs.
        checkPiPSupport()
        setupNotificationObservers() // Monitor app lifecycle for PiP
    }

    private func loadWidgetPreferences() {
        // Each assignment below runs a didSet that saves *every* preference;
        // without this flag the first one overwrote the stored values with defaults.
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "cameraWidgetX") != nil {
            position = CGPoint(x: defaults.double(forKey: "cameraWidgetX"), y: defaults.double(forKey: "cameraWidgetY"))
        }
        isPositionLocked = defaults.bool(forKey: "cameraWidgetLocked")
        isCircular = defaults.bool(forKey: "cameraWidgetCircular")
        let opacity = defaults.double(forKey: "cameraWidgetOpacity")
        previewOpacity = opacity == 0 ? 1 : opacity
        let scale = defaults.double(forKey: "cameraWidgetScale")
        widgetScale = scale == 0 ? 1 : scale
        if defaults.object(forKey: "cameraWidgetFlipped") != nil { isFlipped = defaults.bool(forKey: "cameraWidgetFlipped") }
        updateWidgetSize()
    }

    private func saveWidgetPreferences() {
        guard !isLoadingPreferences else { return }
        let defaults = UserDefaults.standard
        defaults.set(position.x, forKey: "cameraWidgetX")
        defaults.set(position.y, forKey: "cameraWidgetY")
        defaults.set(isPositionLocked, forKey: "cameraWidgetLocked")
        defaults.set(isCircular, forKey: "cameraWidgetCircular")
        defaults.set(previewOpacity, forKey: "cameraWidgetOpacity")
        defaults.set(widgetScale, forKey: "cameraWidgetScale")
        defaults.set(isFlipped, forKey: "cameraWidgetFlipped")
    }

    private func updateWidgetSize() {
        widgetSize = isCircular
            ? CGSize(width: 150 * widgetScale, height: 150 * widgetScale)
            : CGSize(width: 140 * widgetScale, height: 186 * widgetScale)
    }

    func cycleWidgetSize() { widgetScale = widgetScale >= 1.35 ? 0.85 : widgetScale + 0.2 }
    func cyclePreviewOpacity() { previewOpacity = previewOpacity <= 0.65 ? 1 : previewOpacity - 0.2 }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Audio Session Setup
    
    /// Playback-oriented session required for background PiP with the `audio` background mode.
    /// `activate: false` only sets the category (no effect on other apps' audio);
    /// the session is activated when the keep-alive starts.
    private func setupPiPAudioSession(activate: Bool = true, completion: ((Bool) -> Void)? = nil) {
        // A Voice Channel owns the shared session (.playAndRecord/.voiceChat).
        // Changing the category here would cut its microphone, and that
        // category already supports PiP and background audio, so leave it.
        let voiceSessionActive = AudioStreamManager.isVoiceSessionActive
        audioSessionQueue.async {
            if voiceSessionActive {
                if let completion { DispatchQueue.main.async { completion(true) } }
                return
            }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                if activate { try session.setActive(true) }
                print("✅ Audio session configured for PiP (active: \(activate))")
                if let completion { DispatchQueue.main.async { completion(true) } }
            } catch {
                print("⚠️ Failed to setup PiP audio session: \(error.localizedDescription)")
                if let completion { DispatchQueue.main.async { completion(false) } }
            }
        }
    }

    private func startSilentAudioEngine() {
        guard isBackgroundKeepAliveStarting, !isBackgroundKeepAliveActive else { return }

        let engine = AVAudioEngine()
        let format = engine.outputNode.outputFormat(forBus: 0)
        let sourceNode = AVAudioSourceNode(format: format) { _, _, _, audioBufferList -> OSStatus in
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
            AudioStreamManager.isSessionHeldByCameraPiP = false
        }
        isBackgroundKeepAliveStarting = false
    }
    
    /// Plays silent audio so iOS keeps the app alive for PiP while backgrounded.
    private func startBackgroundKeepAlive() {
        guard !isBackgroundKeepAliveActive, !isBackgroundKeepAliveStarting else { return }
        isBackgroundKeepAliveStarting = true
        // Tells the Voice Channel not to deactivate the shared session under PiP.
        AudioStreamManager.isSessionHeldByCameraPiP = true
        keepAliveSessionNeedsRelease = true
        setupPiPAudioSession { [weak self] configured in
            guard let self else { return }
            guard configured else {
                self.isBackgroundKeepAliveStarting = false
                AudioStreamManager.isSessionHeldByCameraPiP = false
                return
            }
            self.startSilentAudioEngine()
        }
    }
    
    /// Stops the silent audio. Called whenever PiP is not (or no longer) showing:
    /// PiP closed from the button or its own window, PiP failed to start, start
    /// retries ran out, the camera was turned off, or the app came to the foreground.
    private func stopBackgroundKeepAlive() {
        isBackgroundKeepAliveStarting = false
        AudioStreamManager.isSessionHeldByCameraPiP = false
        if isBackgroundKeepAliveActive {
            silentAudioEngine?.stop()
            silentAudioEngine = nil
            isBackgroundKeepAliveActive = false
            print("🔇 Background keep-alive stopped")
        }
        
        // Release the session the keep-alive activated — unless a Voice Channel
        // is using it, or PiP is still on screen in the foreground (it is then
        // released when PiP closes). Runs on the same serial queue as
        // activation, so it can't overtake a start still in flight.
        guard keepAliveSessionNeedsRelease, !isPiPActive, !AudioStreamManager.isVoiceSessionActive else { return }
        keepAliveSessionNeedsRelease = false
        audioSessionQueue.async {
            guard !AudioStreamManager.isVoiceSessionActive, !AudioStreamManager.isSessionHeldByCameraPiP else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    
    /// The silent engine stops on its own when the audio route/configuration
    /// changes or the session is interrupted (a phone call, a Voice Channel
    /// taking the session). Without this the manager still believed the
    /// keep-alive was running and never restarted it.
    @objc private func handleSilentEngineConfigurationChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let engine = self.silentAudioEngine,
                  (notification.object as? AVAudioEngine) === engine else { return }
            self.markKeepAliveEngineStopped()
            self.restartKeepAliveIfPiPShowing()
        }
    }
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                if self.isBackgroundKeepAliveActive { self.markKeepAliveEngineStopped() }
            case .ended:
                self.restartKeepAliveIfPiPShowing()
            @unknown default:
                break
            }
        }
    }
    
    /// Drops a silent engine that the system already stopped, leaving the session alone.
    private func markKeepAliveEngineStopped() {
        silentAudioEngine?.stop()
        silentAudioEngine = nil
        isBackgroundKeepAliveActive = false
        print("🔇 Background keep-alive engine stopped by the system")
    }
    
    private func restartKeepAliveIfPiPShowing() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isActive,
                  self.isPiPActive || (self.pipController?.isPictureInPictureActive ?? false) else { return }
            self.startBackgroundKeepAlive()
        }
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

        // Notice when the silent keep-alive engine is stopped by the system
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSilentEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
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
        // The watchdog is stopped when an interruption begins without PiP;
        // start it again or a later stall would go unnoticed.
        if isActive { startSessionHealthMonitoring() }
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
        } else if let stoppedAt = lastPiPStopDate, Date().timeIntervalSince(stoppedAt) < pipStopSettleInterval {
            // Restarting here re-opened PiP every time the tutor closed it.
            print("📱 Scene resigned while PiP was closing - not restarting PiP")
        } else if isActive, isPiPPossible {
            print("📱 App resigning active - enabling auto-PiP intent")
            shouldAutoPiP = true
            // Remember that this start came from the scene deactivating, so it
            // can be undone if the app never actually reaches the background.
            isPiPRequestedByDeactivation = true
            didEnterBackgroundSinceDeactivation = false
            shouldStopPiPOnceStarted = false
            // PiP must be requested while the scene is still foreground-active.
            // Waiting until didEnterBackground is too late on many devices.
            startPiP()
        }
    }
    
    @objc private func handleSceneDidBecomeActive(_ notification: Notification) {
        print("📱 App became active")
        if isPiPRequestedByDeactivation, !didEnterBackgroundSinceDeactivation {
            // The scene only lost focus (Control Center, Notification Center,
            // a permission alert) — the tutor never left the app, so the PiP
            // that deactivation started must not stay on.
            print("📱 Scene reactivated without backgrounding - cancelling auto-PiP")
            cancelDeactivationPiP()
        }
        isPiPRequestedByDeactivation = false
        ensureSessionRunning(reason: "scene became active")
        recoverSampleBufferLayerIfNeeded()
    }
    
    @objc private func handleAppDidEnterBackground(_ notification: Notification) {
        wasActiveBeforeBackground = isActive
        didEnterBackgroundSinceDeactivation = true
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
            // Only the PiP keep-alive needs an audio session; the camera itself
            // captures no audio, so nothing is configured otherwise.
            if isPiPActive || isBackgroundKeepAliveActive {
                setupPiPAudioSession()
            }
            sessionQueue.async { [weak self] in
                session.startRunning()
                DispatchQueue.main.async {
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
        // A stop is still in flight: remember the request and start as soon as
        // it finishes, instead of silently ignoring a quick off-then-on.
        if isStoppingSession {
            isStartPendingAfterStop = true
            sessionLock.unlock()
            return
        }
        // Check if already running or in the process of setting up
        guard captureSession == nil, !isSettingUpSession else {
            sessionLock.unlock()
            return
        }
        isSettingUpSession = true
        isStopPendingAfterSetup = false
        // Unlock before asking for permission: when access is denied the
        // completion runs synchronously and re-locks, and NSLock is not
        // re-entrant, so holding it here froze the main thread.
        sessionLock.unlock()
        
        // Verify permission first
        requestCameraPermission { [weak self] granted in
            guard let self = self, granted else {
                self?.sessionLock.lock()
                self?.isSettingUpSession = false
                self?.sessionLock.unlock()
                return
            }
            
            self.sessionQueue.async {
                self.setupCaptureSession()
                // Queued after setupCaptureSession's own main-queue hop, so
                // captureSession is assigned by the time this runs.
                DispatchQueue.main.async {
                    self.sessionLock.lock()
                    self.isSettingUpSession = false
                    let stopRequested = self.isStopPendingAfterSetup
                    self.isStopPendingAfterSetup = false
                    self.sessionLock.unlock()
                    if stopRequested { self.stopCamera() }
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
            // Off again while the stop is in flight: drop any queued restart.
            isStartPendingAfterStop = false
            sessionLock.unlock()
            return
        }
        // The session isn't assigned until setup finishes; stopping now would
        // orphan it with the camera still running, so stop once it lands.
        if isSettingUpSession {
            isStopPendingAfterSetup = true
            sessionLock.unlock()
            return
        }
        isStoppingSession = true
        sessionLock.unlock()
        
        // Stop PiP first
        if isPiPActive {
            stopPiP()
        }
        // Camera off means no PiP: cancel a start that is still retrying and
        // make sure the silent keep-alive audio never outlives the camera.
        shouldAutoPiP = false
        isPiPStartPending = false
        isPiPRequestedByDeactivation = false
        shouldStopPiPOnceStarted = false
        pipStartGeneration += 1
        isPiPActive = false
        stopBackgroundKeepAlive()
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        
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
        resetSampleBufferProcessor()
        
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
        sessionQueue.async { [weak self] in
            // Flush sample buffer layer before stopping session to prevent frame queuing errors
            sampleLayer?.flush()
            session?.stopRunning()
            
            DispatchQueue.main.async {
                guard let self else { return }
                self.sessionLock.lock()
                self.isStoppingSession = false
                let startRequested = self.isStartPendingAfterStop
                self.isStartPendingAfterStop = false
                self.sessionLock.unlock()
                if startRequested { self.startCamera() }
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
            // Previously this silently did nothing (and mislabelled the state
            // as "restricted"); tell the tutor why the camera didn't appear.
            DispatchQueue.main.async {
                self.reportStatus("No camera available on this device")
            }
            return
        }
        
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            print("❌ Failed to create camera input: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.reportStatus("The camera couldn't be started. Please try again.")
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
            Self.apply(.portrait, to: connection)
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
            self.setupRotationCoordinator(for: camera, previewLayer: layer)
            
            // PiP is only offered while the audio session category allows
            // playback, so set the category now that the camera is on. This
            // does not activate the session or affect other apps' audio.
            if self.isPiPPossible {
                self.setupPiPAudioSession(activate: false)
            }
            
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
    
    /// The processor's pixel buffer pool is used on the video queue, so reset it
    /// there. Resetting from main raced frame processing and dropped a crop.
    private func resetSampleBufferProcessor() {
        videoDataOutputQueue.async {
            SampleBufferProcessor.resetPool()
            SampleBufferProcessor.resetDiagnostics()
        }
    }

    private func updatePiPHostRenderSize(_ renderSize: CMVideoDimensions) {
        let size = CGSize(width: CGFloat(renderSize.width), height: CGFloat(renderSize.height))
        guard size.width > 0, size.height > 0 else { return }
        
        syncPiPTargetAspectRatio(to: size)
        pipSourceHostView?.frame = pipHostFrame(for: size)
        layoutPiPSampleBufferLayerInHost()
        
        pipSampleBufferLayer?.flush()
        hasEnqueuedPiPFrame = false
        resetSampleBufferProcessor()
        
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
        // Live camera: hide the skip-forward/back buttons, which do nothing here.
        controller.requiresLinearPlayback = true
        
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
    
    /// Tracks the rotation the system recommends for showing this camera
    /// upright in the app's interface, and re-applies it whenever it changes.
    private func setupRotationCoordinator(for device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer) {
        rotationObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateVideoOrientationAndMirroring()
            }
        }
    }

    /// Updates orientation and mirroring on capture connections and the preview layer.
    private func updateVideoOrientationAndMirroring() {
        if let coordinator = rotationCoordinator {
            // Preferred path: the coordinator knows which camera is in use, so
            // the front camera is no longer rotated with back-camera angles.
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            for connection in [videoDataOutput?.connection(with: .video), previewLayer?.connection].compactMap({ $0 }) {
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = isFlipped
                }
            }
            return
        }

        // Fallback (no coordinator yet): interface-orientation table.
        let orientation = currentVideoOrientation

        if let connection = videoDataOutput?.connection(with: .video) {
            Self.apply(orientation, to: connection)
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isFlipped
            }
        }

        if let previewConnection = previewLayer?.connection {
            Self.apply(orientation, to: previewConnection)
            if previewConnection.isVideoMirroringSupported {
                previewConnection.automaticallyAdjustsVideoMirroring = false
                previewConnection.isVideoMirrored = isFlipped
            }
        }
    }

    /// Maps the active scene's interface orientation to a capture orientation
    /// Rotation angles replace `videoOrientation` (deprecated in iOS 17):
    /// landscapeRight is the sensor's native 0°, portrait is 90°.
    private static func apply(_ orientation: AVCaptureVideoOrientation, to connection: AVCaptureConnection) {
        let angle: CGFloat
        switch orientation {
        case .landscapeRight: angle = 0
        case .portrait: angle = 90
        case .landscapeLeft: angle = 180
        case .portraitUpsideDown: angle = 270
        @unknown default: angle = 90
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

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
        
        guard isPiPPossible else {
            reportStatus("Picture in Picture isn't supported on this device")
            return
        }
        
        // An explicit tap replaces any start made by the scene deactivating.
        isPiPRequestedByDeactivation = false
        shouldStopPiPOnceStarted = false
        
        if !isActive {
            print("   → Camera not active, starting camera first...")
            shouldAutoPiP = true
            pipStartRetryCount = 0
            startCamera()
            schedulePiPStartRetry(after: 0.8)
            return
        }

        // Ensure we have a valid controller before proceeding.
        guard pipController != nil else {
            print("⚠️ PiP controller not ready – attempting setup again.")
            if #available(iOS 15.0, *) {
                setupPiPController()
            }
            shouldAutoPiP = true
            pipStartRetryCount = 0
            schedulePiPStartRetry(after: 0.5)
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
    
    /// Re-attempts startPiP() after a delay. The attempt is dropped if PiP was
    /// stopped or cancelled in the meantime (generation moved on), so a
    /// cancelled start can't come back half a second later.
    private func schedulePiPStartRetry(after delay: TimeInterval) {
        let generation = pipStartGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pipStartGeneration == generation, self.shouldAutoPiP else { return }
            self.startPiP()
        }
    }
    
    /// PiP could not be started. Ends the attempt, makes sure the silent
    /// keep-alive audio is not left running, and tells the tutor — unless the
    /// attempt was made automatically as the app lost focus.
    private func handlePiPStartGaveUp() {
        let wasAutomatic = isPiPRequestedByDeactivation
        shouldAutoPiP = false
        isPiPStartPending = false
        pipStartRetryCount = 0
        pipStartGeneration += 1
        stopBackgroundKeepAlive()
        if !wasAutomatic {
            reportStatus("Picture in Picture isn't available right now")
        }
    }
    
    /// Starts Picture‑in‑Picture
    func startPiP() {
        guard isActive || isSettingUpSession else { return }
        
        if #available(iOS 15.0, *) {
            attemptPiPControllerSetupIfReady()
        }
        
        guard let controller = pipController else {
            guard pipStartRetryCount < maxPiPStartRetries else {
                print("❌ PiP controller not available after \(maxPiPStartRetries) retries")
                handlePiPStartGaveUp()
                return
            }
            pipStartRetryCount += 1
            print("⚠️ PiP controller not available – retry \(pipStartRetryCount)/\(maxPiPStartRetries)")
            schedulePiPStartRetry(after: 0.5)
            return
        }
        
        if controller.isPictureInPictureActive {
            print("✅ PiP already active")
            pipStartRetryCount = 0
            return
        }

        // Scene, frame and button callbacks can all request a start within a
        // few milliseconds; one request is enough.
        guard !isPiPStartPending else { return }
        
        if controller.isPictureInPicturePossible {
            print("🎬 Starting PiP...")
            pipStartRetryCount = 0
            isPiPStartPending = true
            // Silent audio so PiP stays alive in the background. Started only
            // now that iOS says PiP can start — not while still retrying — and
            // stopped again below / in the delegate if the start doesn't land.
            startBackgroundKeepAlive()
            controller.startPictureInPicture()
            // If iOS never reports back, don't block PiP for good.
            let generation = pipStartGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.pipStartGeneration == generation, self.isPiPStartPending else { return }
                self.isPiPStartPending = false
                if !self.isPiPActive, self.pipController?.isPictureInPictureActive != true {
                    print("❌ PiP start was never confirmed by iOS")
                    self.handlePiPStartGaveUp()
                }
            }
        } else {
            guard pipStartRetryCount < maxPiPStartRetries else {
                let layerStatus = pipSampleBufferLayer.map { String(describing: $0.status) } ?? "nil"
                print("❌ PiP not possible after \(maxPiPStartRetries) retries (layer status: \(layerStatus), in hierarchy: \(pipSampleBufferLayer?.superlayer != nil), frames enqueued: \(hasEnqueuedPiPFrame))")
                handlePiPStartGaveUp()
                return
            }
            pipStartRetryCount += 1
            print("⚠️ PiP not possible yet – retry \(pipStartRetryCount)/\(maxPiPStartRetries)")
            schedulePiPStartRetry(after: 0.5)
        }
    }
    
    /// Stops Picture-in-Picture
    func stopPiP() {
        shouldAutoPiP = false
        pipStartRetryCount = 0
        isPiPStartPending = false
        pipStartGeneration += 1 // cancels any delayed start retries
        lastPiPStopDate = Date()
        
        if let controller = pipController, controller.isPictureInPictureActive {
            print("⏹️ Stopping PiP...")
            controller.stopPictureInPicture()
        }
        
        isPiPActive = false
        stopBackgroundKeepAlive()
    }
    
    /// Undoes a PiP start that was triggered by the scene deactivating when
    /// the app then came straight back without reaching the background.
    private func cancelDeactivationPiP() {
        let startInFlight = isPiPStartPending
        let showing = isPiPActive || (pipController?.isPictureInPictureActive ?? false)
        if showing || startInFlight {
            // If iOS is still bringing PiP up, close it as soon as it reports started.
            shouldStopPiPOnceStarted = startInFlight && !showing
            stopPiP()
        } else {
            // Nothing on screen yet: just drop the intent and the retry chain.
            // (No stop date, so leaving the app right afterwards still starts PiP.)
            shouldAutoPiP = false
            pipStartRetryCount = 0
            pipStartGeneration += 1
            stopBackgroundKeepAlive()
        }
    }
    
    // MARK: - Status Messages
    
    /// Shows a short notice. With the camera on it appears in the camera
    /// overlay; otherwise (the overlay isn't on screen) it is shown as an alert.
    private func reportStatus(_ message: String) {
        print("ℹ️ Camera status: \(message)")
        guard isActive else {
            statusMessage = nil
            guard let presenter = Self.topViewController, presenter.presentedViewController == nil else { return }
            let alert = UIAlertController(title: "Camera", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(alert, animated: true)
            return
        }
        statusMessage = message
        statusMessageClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        statusMessageClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
    
    private static var topViewController: UIViewController? {
        var top = activeKeyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
    
    // MARK: - Drag Position
    
    /// Updates the camera widget position, keeping it within bounds
    func updatePosition(to point: CGPoint, in bounds: CGRect) {
        // Ensure widget stays within screen bounds
        let maxX = max(bounds.width - widgetSize.width, 0)
        let maxY = max(bounds.height - widgetSize.height, 0)
        
        position = CGPoint(
            x: min(max(point.x, 0), maxX),
            y: min(max(point.y, 0), maxY)
        )
    }
    
    /// Pulls the widget back inside the container after the container (rotation)
    /// or the widget (resize, shape) changes size, so it can't be left off-screen.
    func clampPosition(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let clamped = CGPoint(
            x: min(max(position.x, 0), max(size.width - widgetSize.width, 0)),
            y: min(max(position.y, 0), max(size.height - widgetSize.height, 0))
        )
        if clamped != position { position = clamped }
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
        if shouldStopPiPOnceStarted {
            // This start was cancelled (the app never left the foreground)
            // before iOS finished bringing PiP up.
            shouldStopPiPOnceStarted = false
            isPiPStartPending = false
            stopPiP()
            return
        }
        DispatchQueue.main.async { self.isPiPStartPending = false }
        activatePiPBackgroundMode()
        ensureSessionRunning(reason: "PiP did start")
        recoverSampleBufferLayerIfNeeded()
        DispatchQueue.main.async {
            self.isPiPActive = true
        }
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("⏹️ PiP will stop")
        // Also covers PiP closed from its own window, not just our button.
        lastPiPStopDate = Date()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ PiP did stop - returning to inline mode")
        DispatchQueue.main.async {
            self.lastPiPStopDate = Date()
            self.isPiPStartPending = false
            self.isPiPActive = false
            // Don't auto-restart PiP after manual stop
            self.shouldAutoPiP = false
            self.shouldStopPiPOnceStarted = false
            self.pipStartGeneration += 1
            // Covers every way PiP can close — including the X on the PiP
            // window itself — so the silent audio never outlives PiP.
            self.stopBackgroundKeepAlive()
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("❌ PiP failed to start: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isPiPActive = false
            self.shouldStopPiPOnceStarted = false
            // Stops the keep-alive audio and tells the tutor (unless automatic).
            self.handlePiPStartGaveUp()
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // Restore the app's UI when PiP is stopped by tapping on it
        print("🔄 Restoring UI from PiP - user tapped the PiP window")
        
        // Ensure camera session is running
        if let session = captureSession, !session.isRunning {
            sessionQueue.async {
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
            // Only while PiP is really on screen, so this can't start silent audio without PiP.
            if isPiPActive || pictureInPictureController.isPictureInPictureActive {
                startBackgroundKeepAlive()
            }
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
