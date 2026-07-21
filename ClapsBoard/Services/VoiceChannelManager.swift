//
//  VoiceChannelManager.swift
//  ClapsBoard
//
//  Manages peer-to-peer voice communication using Multipeer Connectivity
//  This provides legitimate VoIP functionality for the app
//

import Foundation
import MultipeerConnectivity
import AVFoundation
import Combine

/// Voice channel state
enum VoiceChannelState: Equatable {
    case idle
    case hosting(code: String)
    case joining
    case connected(peerCount: Int)
    case error(String)
    
    var isActive: Bool {
        switch self {
        case .hosting, .joining, .connected:
            return true
        default:
            return false
        }
    }
}

/// Connected peer info
struct VoiceChannelPeer: Identifiable, Hashable {
    let id: String
    let displayName: String
    var isMuted: Bool = false
    
    init(peerID: MCPeerID) {
        self.id = peerID.displayName
        self.displayName = peerID.displayName
    }
}

/// Manages voice channel using Multipeer Connectivity
class VoiceChannelManager: NSObject, ObservableObject {

    // MARK: - Published Properties
    @Published var state: VoiceChannelState = .idle
    @Published var connectedPeers: [VoiceChannelPeer] = []
    @Published var isMuted: Bool = false
    @Published var isAudioActive: Bool = false
    @Published var localAudioLevel: Float = 0.0
    @Published var remoteAudioLevel: Float = 0.0

    // MARK: - Blocked & Reported Users (persisted)
    private static let blockedUserIDsKey = "VoiceChannelBlockedUserIDs"
    private static let reportedUserIDsKey = "VoiceChannelReportedUserIDs"

    private var blockedUserIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(blockedUserIDs), forKey: Self.blockedUserIDsKey)
        }
    }

    private var reportedUserIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(reportedUserIDs), forKey: Self.reportedUserIDsKey)
        }
    }

    // MARK: - Private Properties
    private var peerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private let serviceType = "clapsboard-vc" // Max 15 chars, lowercase + hyphens
    private var sessionCode: String = ""
    private var targetSessionCode: String = ""

    private var audioStreamManager: AudioStreamManager?
    
    // MARK: - Initialization
    override init() {
        let blockedArray = UserDefaults.standard.stringArray(forKey: Self.blockedUserIDsKey) ?? []
        self.blockedUserIDs = Set(blockedArray)

        let reportedArray = UserDefaults.standard.stringArray(forKey: Self.reportedUserIDsKey) ?? []
        self.reportedUserIDs = Set(reportedArray)

        super.init()
        setupPeerID()
        setupSession()
    }
    
    deinit {
        cleanup()
    }
    
    private func cleanup() {
        // 1. Set delegates to nil immediately to stop callbacks
        advertiser?.delegate = nil
        browser?.delegate = nil
        session?.delegate = nil
        audioStreamManager?.delegate = nil
        
        // 2. Stop services
        stopServices()
        audioStreamManager?.stopCapturing()
        audioStreamManager = nil
        
        // 3. Disconnect session
        session?.disconnect()
        session = nil
    }
    
    // MARK: - Setup
    private func setupPeerID() {
        // Create a unique peer ID with device name
        let deviceName = UIDevice.current.name
        peerID = MCPeerID(displayName: deviceName)
    }
    
    private func setupSession() {
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }
    
    // MARK: - Public Methods
    
    /// Generate a random 4-digit session code
    private func generateSessionCode() -> String {
        return String(format: "%04d", Int.random(in: 1000...9999))
    }
    
    /// Host a new voice channel
    func hostChannel() {
        stopServices()
        
        sessionCode = generateSessionCode()
        
        let discoveryInfo: [String: String] = ["code": sessionCode]
        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: discoveryInfo,
            serviceType: serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        
        startAudioManager()
        
        DispatchQueue.main.async {
            self.state = .hosting(code: self.sessionCode)
        }
    }
    
    /// Join an existing voice channel with a code
    func joinChannel(code: String) {
        stopServices()
        
        targetSessionCode = code
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        
        DispatchQueue.main.async {
            self.state = .joining
        }
    }
    
    /// Disconnect from the voice channel
    func disconnect() {
        stopServices()
        audioStreamManager?.stopCapturing()
        session.disconnect()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.state = .idle
            self.connectedPeers = []
            self.isAudioActive = false
        }
    }
    
    /// Toggle mute state
    func toggleMute() {
        isMuted.toggle()
        audioStreamManager?.setMuted(isMuted)
    }

    /// Block a user from future connections
    /// - Parameter peer: The peer to block
    func blockUser(_ peer: VoiceChannelPeer) {
        blockedUserIDs.insert(peer.id)

        // Immediately disconnect from this peer if connected
        if let mcPeerID = session.connectedPeers.first(where: { $0.displayName == peer.id }) {
            session.cancelConnectPeer(mcPeerID)
        }

        updateConnectedPeers()
    }

    /// Report a user for offensive behavior
    /// - Parameter peer: The peer to report
    func reportUser(_ peer: VoiceChannelPeer) {
        reportedUserIDs.insert(peer.id)
    }

    /// Check if a user is blocked
    /// - Parameter peerID: The peer ID to check
    /// - Returns: True if the peer is blocked
    func isUserBlocked(_ peerID: String) -> Bool {
        return blockedUserIDs.contains(peerID)
    }
    
    // MARK: - Private Methods
    
    private func stopServices() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
    }
    
    private func startAudioManager() {
        if audioStreamManager == nil {
            audioStreamManager = AudioStreamManager()
            audioStreamManager?.delegate = self
        }
        audioStreamManager?.startCapturing()
        DispatchQueue.main.async {
            self.isAudioActive = true
        }
    }
    
    private func updateConnectedPeers() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.connectedPeers = self.session.connectedPeers.map { VoiceChannelPeer(peerID: $0) }
            
            if self.connectedPeers.isEmpty {
                if case .connected = self.state {
                    if self.advertiser != nil {
                        self.state = .hosting(code: self.sessionCode)
                    } else {
                        self.state = .idle
                    }
                }
            } else {
                self.state = .connected(peerCount: self.connectedPeers.count)
            }
        }
    }
}

// MARK: - MCSessionDelegate
extension VoiceChannelManager: MCSessionDelegate {
    
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        print("👤 Peer \(peerID.displayName) state changed: \(state.rawValue)")
        
        if state == .connected {
            startAudioManager()
        }
        
        updateConnectedPeers()
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Audio data is received here
        audioStreamManager?.playReceivedData(data)
    }
    
    // Required but unused
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension VoiceChannelManager: MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Reject invitations from blocked users
        if isUserBlocked(peerID.displayName) {
            print("Blocked peer \(peerID.displayName) tried to join, rejecting invitation")
            invitationHandler(false, nil)
            return
        }

        invitationHandler(true, session)
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.state = .error("Failed to host: \(error.localizedDescription)")
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension VoiceChannelManager: MCNearbyServiceBrowserDelegate {
    
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let code = info?["code"], code == targetSessionCode else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.state = .error("Failed to search: \(error.localizedDescription)")
        }
    }
}

// MARK: - AudioStreamManagerDelegate
extension VoiceChannelManager: AudioStreamManagerDelegate {
    
    func audioStreamManager(_ manager: AudioStreamManager, didCaptureAudioData data: Data) {
        // Send audio data to all connected peers
        guard !session.connectedPeers.isEmpty else { return }
        
        do {
            // Use .unreliable for audio packet transmission (standard for VoIP)
            try session.send(data, toPeers: session.connectedPeers, with: .unreliable)
        } catch {
            print("❌ Failed to send audio: \(error)")
        }
    }
    
    func audioStreamManager(_ manager: AudioStreamManager, didUpdateLocalAudioLevel level: Float) {
        DispatchQueue.main.async {
            self.localAudioLevel = level
        }
    }
    
    func audioStreamManager(_ manager: AudioStreamManager, didUpdateRemoteAudioLevel level: Float) {
        DispatchQueue.main.async {
            self.remoteAudioLevel = level
        }
    }
}
