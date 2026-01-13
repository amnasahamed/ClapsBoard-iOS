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

// MARK: - Camera Manager with System PiP Support
/// Camera manager with TRUE iOS Picture-in-Picture support (like Zoom/Google Meet)
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
    
    // PiP Components
    private var pipController: AVPictureInPictureController?
    private var pipVideoCallViewController: AVPictureInPictureVideoCallViewController?
    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer? // Internal access for CameraPreviewView
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private let videoDataOutputQueue = DispatchQueue(label: "com.clapsboard.videoDataOutput", qos: .userInteractive)
    
    // Lifecycle tracking
    private var shouldAutoPiP: Bool = false // Auto-start PiP when backgrounding
    private var wasActiveBeforeBackground: Bool = false
    
    var widgetSize: CGSize = CGSize(width: 140, height: 186)
    
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
            // HIG: For camera PiP to remain active in background, we should use .playAndRecord 
            // and .videoChat mode, which tells the system this is a video call session.
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            print("⚠️ Failed to setup audio session: \(error.localizedDescription)")
            // Retry once after a short delay - audio session can fail if another app is using it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
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
    
    // MARK: - PiP Support Check
    private func checkPiPSupport() {
        // Check if PiP is supported on this device
        isPiPPossible = AVPictureInPictureController.isPictureInPictureSupported()
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
        
        // Handle app entering foreground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func handleSceneWillResignActive(_ notification: Notification) {
        // App is about to lose focus (Home button pressed, swipe up, etc.)
        if isActive && !isPiPActive && shouldAutoPiP {
            print("📱 App resigning active - auto-starting PiP")
            startPiP()
        }
    }
    
    @objc private func handleSceneDidBecomeActive(_ notification: Notification) {
        // App became active again
        print("📱 App became active")
    }
    
    @objc private func handleAppDidEnterBackground(_ notification: Notification) {
        // App fully entered background
        wasActiveBeforeBackground = isActive
        print("📱 App entered background - camera active: \(isActive), PiP active: \(isPiPActive)")
        
        // If camera is active but PiP isn't, try to start it
        if isActive && !isPiPActive && shouldAutoPiP {
            startPiP()
        }
    }
    
    @objc private func handleAppWillEnterForeground(_ notification: Notification) {
        // App is returning to foreground
        print("📱 App entering foreground - was active: \(wasActiveBeforeBackground)")
        
        // Keep capture session running for smooth transition
        if wasActiveBeforeBackground && captureSession?.isRunning == false {
            let session = captureSession
            DispatchQueue.global(qos: .userInitiated).async {
                session?.startRunning()
            }
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
        // Check if already running
        guard captureSession == nil else { return }
        
        // Verify permission first
        requestCameraPermission { [weak self] granted in
            guard granted else { return }
            
            DispatchQueue.global(qos: .userInitiated).async {
                self?.setupCaptureSession()
            }
        }
    }
    
    /// Stops the camera and releases resources
    func stopCamera() {
        // Stop PiP first
        if isPiPActive {
            stopPiP()
        }
        
        // HIG: stopRunning() is a blocking call, move to background
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stopRunning()
        }
        
        captureSession = nil
        previewLayer = nil
        sampleBufferDisplayLayer = nil
        pipController = nil
        
        DispatchQueue.main.async {
            self.isActive = false
            self.isPiPActive = false
        }
    }
    
    /// Sets up the capture session for live preview with PiP support
    private func setupCaptureSession() {
        let session = AVCaptureSession()
        session.sessionPreset = .high // Higher quality for PiP
        
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
        
        // Configure video connection for proper orientation
        if let connection = dataOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            // Mirror will be applied in the delegate
            connection.isVideoMirrored = isFlipped
        }
        
        // Setup preview layer
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        
        // Setup sample buffer display layer for PiP
        let sampleLayer = AVSampleBufferDisplayLayer()
        sampleLayer.videoGravity = .resizeAspectFill
        
        // Configure sample layer for better performance
        sampleLayer.preventsCapture = false // Allow screen recording
        if #available(iOS 17.0, *) {
            sampleLayer.preventsDisplaySleepDuringVideoPlayback = false
        }
        
        // Ensure the layer has a non‑zero frame so the system recognises it for PiP
        sampleLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        sampleLayer.opacity = 0.01 // Almost invisible but active
        
        // Start session - iOS will show the camera indicator (green dot)
        session.startRunning()
        
        DispatchQueue.main.async {
            self.captureSession = session
            self.previewLayer = layer
            self.sampleBufferDisplayLayer = sampleLayer
            self.isActive = true
            
            // Setup PiP controller after session is running
            self.setupPiPController()
            self.updateVideoOrientationAndMirroring()
        }
    }
    
    /// Updates orientation and mirroring on the current connection
    private func updateVideoOrientationAndMirroring() {
        guard let connection = videoDataOutput?.connection(with: .video) else { return }
        
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = isFlipped
        }
    }
    
    // MARK: - Picture-in-Picture Setup
    
    /// Sets up AVPictureInPictureController for system‑wide PiP
    private func setupPiPController() {
        guard isPiPPossible,
              let sampleLayer = sampleBufferDisplayLayer else {
            print("PiP not supported or sample layer not ready")
            return
        }
        
        // Use the video call content source for live camera PiP
        if #available(iOS 15.0, *) {
            // Create PiP content source using sample buffer layer
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: sampleLayer,
                playbackDelegate: self
            )
            
            let controller = AVPictureInPictureController(contentSource: contentSource)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            
            pipController = controller
            
            print("PiP Controller setup successfully")
        } else {
            print("PiP for live camera requires iOS 15+")
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
        print("   - PiP possible: \(isPiPPossible)")
        print("   - PiP controller exists: \(pipController != nil)")
        print("   - Sample buffer layer exists: \(sampleBufferDisplayLayer != nil)")
        
        // Ensure we have a valid controller before proceeding
        guard pipController != nil else {
            print("⚠️ PiP controller not ready – attempting setup again.")
            setupPiPController()
            return
        }
        
        if !isActive {
            print("   → Camera not active, starting camera first...")
            startCamera()
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
            startPiP()
        }
    }
    
    /// Starts Picture‑in‑Picture
    func startPiP() {
        guard let controller = pipController else {
            print("⚠️ PiP controller not available – retrying in 0.5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startPiP()
            }
            return
        }
        
        if controller.isPictureInPictureActive {
            print("✅ PiP already active")
            return
        }
        
        // Ensure audio session is active before starting PiP
        setupAudioSession()
        
        if controller.isPictureInPicturePossible {
            print("🎬 Starting PiP...")
            controller.startPictureInPicture()
            
            // Set flag immediately to ensure UI responsiveness
            DispatchQueue.main.async {
                self.isPiPActive = true
                self.shouldAutoPiP = true
            }
        } else {
            print("⚠️ PiP not possible yet – will retry when sample buffer ready")
            // Simple retry after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startPiP()
            }
        }
    }
    
    /// Stops Picture-in-Picture
    func stopPiP() {
        shouldAutoPiP = false
        
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
        // Apply mirror effect for front camera
        // NOTE: Accessing @Published property isFlipped from background thread is unsafe.
        // For simple booleans in high-frequency callbacks, we'll check it on main if needed,
        // but it's better to update the connection once when it changes.
        // However, since we're already here, we'll use the connection's current state.
        
        // Feed sample buffer to PiP layer
        guard let sampleLayer = sampleBufferDisplayLayer else { return }
        
        // Ensure we're on the right thread and layer is ready
        if sampleLayer.status == .failed {
            sampleLayer.flush()
            return // Don't enqueue when failed, wait for next frame
        }
        
        // Only enqueue if the layer is ready to receive
        if sampleLayer.isReadyForMoreMediaData {
            sampleLayer.enqueue(sampleBuffer)
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension CameraManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎬 PiP will start")
        DispatchQueue.main.async {
            self.isPiPActive = true
        }
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ PiP did start - camera now works outside the app!")
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
            // Resume camera if needed
            if let session = captureSession, !session.isRunning {
                print("▶️ Resuming camera session")
                DispatchQueue.global(qos: .userInitiated).async {
                    session.startRunning()
                }
            }
        } else {
            // For live camera, we typically don't pause
            // But we respect the user's intent if they explicitly pause
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
        // Handle size changes if needed
        print("📐 PiP render size changed to: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        // Not applicable for live camera - no seeking in live streams
        print("⏭️ Skip requested (not applicable for live camera)")
        completion()
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let cameraManager: CameraManager
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Ensure preview layer is added and frame is updated
        if let previewLayer = cameraManager.previewLayer {
            if previewLayer.superlayer != uiView.layer {
                // Remove from previous superlayer if needed
                previewLayer.removeFromSuperlayer()
                uiView.layer.addSublayer(previewLayer)
            }
            
            // Update frame safely on main thread
            DispatchQueue.main.async {
                previewLayer.frame = uiView.bounds
                
                // Apply flip transform for mirror effect
                if cameraManager.isFlipped {
                    previewLayer.transform = CATransform3DMakeScale(-1, 1, 1)
                } else {
                    previewLayer.transform = CATransform3DIdentity
                }
            }
        }
        
        // Ensure PiP layer is added to hierarchy for system requirements
        if let pipLayer = cameraManager.sampleBufferDisplayLayer {
            if pipLayer.superlayer != uiView.layer {
                // HIG: The layer must have a non-zero frame to be considered "active" by iOS for PiP
                // Even if it's placed behind other views or is very small
                pipLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                pipLayer.opacity = 0.01 // Nearly invisible but present
                uiView.layer.addSublayer(pipLayer)
            }
        }
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

