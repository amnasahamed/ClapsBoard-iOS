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
import UIKit

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
    /// The peer's full Multipeer name ("iPhone 3F9A2C"): device name plus a
    /// per-install code. Stable and unique, so it is safe to block by.
    let id: String
    /// Friendlier label for the list: the device name without the code.
    let displayName: String
    /// The per-install code, shown small so two "iPhone"s can be told apart.
    let shortCode: String
    var isMuted: Bool = false

    init(name: String) {
        id = name
        // The last word is the install code when it is 6 hex characters.
        if let space = name.lastIndex(of: " ") {
            let suffix = name[name.index(after: space)...]
            if suffix.count == 6, suffix.allSatisfy({ $0.isHexDigit }) {
                displayName = String(name[..<space])
                shortCode = String(suffix)
                return
            }
        }
        displayName = name
        shortCode = ""
    }

    init(peerID: MCPeerID) {
        self.init(name: peerID.displayName)
    }
}

/// Manages voice channel using Multipeer Connectivity.
/// Public methods and published state are main-thread only.
class VoiceChannelManager: NSObject, ObservableObject {

    /// One manager for the whole app. It used to be owned by the Voice Channel
    /// screen, so leaving that screen (to use the board) destroyed the channel.
    static let shared = VoiceChannelManager()

    // MARK: - Published Properties
    @Published var state: VoiceChannelState = .idle
    @Published var connectedPeers: [VoiceChannelPeer] = []
    @Published var isMuted: Bool = false
    /// False while the microphone engine is stopped (e.g. during a phone call).
    @Published var isAudioActive: Bool = false
    @Published var localAudioLevel: Float = 0.0
    /// Speaking level per connected peer, keyed by `VoiceChannelPeer.id`.
    @Published var peerAudioLevels: [String: Float] = [:]
    /// The code students join with, for as long as this device is hosting —
    /// including after the first student has connected.
    @Published private(set) var hostCode: String?
    /// Why the last channel ended, when it wasn't ended with the button.
    @Published var notice: String?
    @Published private(set) var blockedPeers: [VoiceChannelPeer] = []

    // MARK: - Blocked & Reported Users (persisted)
    private static let blockedUserIDsKey = "VoiceChannelBlockedUserIDs"
    private static let reportedUserIDsKey = "VoiceChannelReportedUserIDs"
    private static let peerSuffixKey = "VoiceChannelPeerSuffix"
    private static let blockListResetKey = "VoiceChannelBlockListResetForUniqueNames"

    /// Sent by the host to a peer it has blocked, asking that device to leave.
    /// (Multipeer has no way to disconnect a single connected peer.) Audio
    /// packets always have an even length, so this can't be mistaken for one.
    private static let removalMessage = Data("CBVC-REMOVED!".utf8)

    /// Read on the Multipeer and audio threads as well as main, hence the lock.
    private let blockLock = NSLock()
    private var blockedUserIDs: Set<String>

    private var reportedUserIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(reportedUserIDs), forKey: Self.reportedUserIDsKey)
        }
    }

    // MARK: - Private Properties
    private enum Role { case none, host, joiner }
    private var role: Role = .none

    private var peerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private let serviceType = "clapsboard-vc" // Max 15 chars, lowercase + hyphens
    private var sessionCode: String = ""
    private var targetSessionCode: String = ""
    /// The host this device invited when joining; only it may remove us.
    private var hostPeerName: String?

    private var audioStreamManager: AudioStreamManager?
    private var joinTimeoutWork: DispatchWorkItem?
    private let joinTimeout: TimeInterval = 20

    // Level meters: decay to zero when packets stop arriving.
    private var levelDecayTimer: Timer?
    private var lastLocalLevelDate = Date.distantPast
    private var lastPeerLevelDates: [String: Date] = [:]

    // MARK: - Initialization
    override init() {
        // Entries saved before peers had unique names are bare device names
        // such as "iPhone", which match every phone. They can't identify
        // anyone, so drop them once.
        if !UserDefaults.standard.bool(forKey: Self.blockListResetKey) {
            UserDefaults.standard.removeObject(forKey: Self.blockedUserIDsKey)
            UserDefaults.standard.set(true, forKey: Self.blockListResetKey)
        }
        let blockedArray = UserDefaults.standard.stringArray(forKey: Self.blockedUserIDsKey) ?? []
        self.blockedUserIDs = Set(blockedArray)

        let reportedArray = UserDefaults.standard.stringArray(forKey: Self.reportedUserIDsKey) ?? []
        self.reportedUserIDs = Set(reportedArray)

        super.init()
        blockedPeers = blockedArray.sorted().map { VoiceChannelPeer(name: $0) }
        setupPeerID()
        setupSession()

        // The app tells App Review the channel works only while ClapsBoard is
        // open. Without this the `audio` background mode kept the microphone
        // capturing after the tutor left the app.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanup()
    }

    private func cleanup() {
        // 1. Set delegates to nil immediately to stop callbacks
        advertiser?.delegate = nil
        browser?.delegate = nil
        session?.delegate = nil
        audioStreamManager?.delegate = nil

        // 2. Stop services
        levelDecayTimer?.invalidate()
        joinTimeoutWork?.cancel()
        stopServices()
        audioStreamManager?.stopCapturing()
        audioStreamManager = nil

        // 3. Disconnect session
        session?.disconnect()
        session = nil
    }

    @objc private func handleAppDidEnterBackground() {
        guard state.isActive else { return }
        endSession(notice: "The voice channel ended because ClapsBoard went to the background.")
    }

    // MARK: - Setup
    private func setupPeerID() {
        // Since iOS 16 UIDevice.current.name is the generic "iPhone" for every
        // device, and peers are identified (and blocked) by this name. Add a
        // short code that stays the same for this install, so blocking one
        // student no longer blocks all of them and the list can tell them apart.
        let defaults = UserDefaults.standard
        var suffix = defaults.string(forKey: Self.peerSuffixKey) ?? ""
        if suffix.isEmpty {
            suffix = String(UUID().uuidString.prefix(6))
            defaults.set(suffix, forKey: Self.peerSuffixKey)
        }
        // MCPeerID rejects display names longer than 63 UTF-8 bytes.
        var deviceName = UIDevice.current.name
        while deviceName.utf8.count > 50 { deviceName.removeLast() }
        peerID = MCPeerID(displayName: "\(deviceName) \(suffix)")
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

    private static let microphoneDeniedMessage =
        "Microphone access is off. Turn it on in Settings › ClapsBoard › Microphone to use the voice channel."

    /// Host a new voice channel
    func hostChannel() {
        notice = nil
        // Ask for (or check) the microphone first. Without access the channel
        // used to show "Live" while sending silence.
        AudioStreamManager.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.endSession(state: .error(Self.microphoneDeniedMessage))
                return
            }
            self.beginHosting()
        }
    }

    private func beginHosting() {
        stopServices()
        joinTimeoutWork?.cancel()

        sessionCode = generateSessionCode()
        role = .host

        let discoveryInfo: [String: String] = ["code": sessionCode]
        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: discoveryInfo,
            serviceType: serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        guard startAudioManager() else { return }

        hostCode = sessionCode
        state = .hosting(code: sessionCode)
    }

    /// Join an existing voice channel with a code
    func joinChannel(code: String) {
        notice = nil
        AudioStreamManager.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.endSession(state: .error(Self.microphoneDeniedMessage))
                return
            }
            self.beginJoining(code: code)
        }
    }

    private func beginJoining(code: String) {
        stopServices()

        role = .joiner
        hostCode = nil
        hostPeerName = nil
        targetSessionCode = code
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        state = .joining

        // Don't search forever when the code is wrong or the host isn't nearby.
        joinTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .joining = self.state else { return }
            self.endSession(state: .error("No channel found with that code. Check the code, and that both devices are on the same Wi‑Fi with Bluetooth on."))
        }
        joinTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + joinTimeout, execute: work)
    }

    /// Disconnect from the voice channel
    func disconnect() {
        endSession()
    }

    /// Ends hosting or joining completely: stops advertising/browsing, turns
    /// the microphone off, releases the audio session and leaves the session.
    /// Every way a channel can end goes through here.
    private func endSession(state newState: VoiceChannelState = .idle, notice newNotice: String? = nil) {
        joinTimeoutWork?.cancel()
        joinTimeoutWork = nil
        stopServices()
        levelDecayTimer?.invalidate()
        levelDecayTimer = nil
        audioStreamManager?.stopCapturing()
        session.disconnect()

        role = .none
        sessionCode = ""
        targetSessionCode = ""
        hostPeerName = nil

        state = newState
        hostCode = nil
        connectedPeers = []
        isAudioActive = false
        localAudioLevel = 0
        peerAudioLevels = [:]
        lastPeerLevelDates = [:]
        notice = newNotice
    }

    /// Toggle mute state
    func toggleMute() {
        isMuted.toggle()
        audioStreamManager?.setMuted(isMuted)
        if isMuted { localAudioLevel = 0 }
    }

    /// Block a user: their audio is dropped, nothing more is sent to them,
    /// they leave the participant list at once and can't rejoin a channel
    /// hosted on this device.
    /// - Parameter peer: The peer to block
    func blockUser(_ peer: VoiceChannelPeer) {
        blockLock.lock()
        blockedUserIDs.insert(peer.id)
        let snapshot = blockedUserIDs
        blockLock.unlock()
        persistBlockList(snapshot)

        if let mcPeerID = session.connectedPeers.first(where: { $0.displayName == peer.id }) {
            if role == .host {
                // Ask their device to leave the channel.
                try? session.send(Self.removalMessage, toPeers: [mcPeerID], with: .reliable)
            }
            session.cancelConnectPeer(mcPeerID)
        }

        audioStreamManager?.removePeer(peer.id)
        updateConnectedPeers()
    }

    /// Remove a peer from the blocked list
    func unblockUser(_ peer: VoiceChannelPeer) {
        blockLock.lock()
        blockedUserIDs.remove(peer.id)
        let snapshot = blockedUserIDs
        blockLock.unlock()
        persistBlockList(snapshot)
        updateConnectedPeers()
    }

    private func persistBlockList(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.blockedUserIDsKey)
        blockedPeers = ids.sorted().map { VoiceChannelPeer(name: $0) }
    }

    /// Report a user for offensive behavior. Nothing is sent anywhere (the app
    /// has no server): the peer is flagged on this device and blocked.
    /// - Parameter peer: The peer to report
    func reportUser(_ peer: VoiceChannelPeer) {
        reportedUserIDs.insert(peer.id)
        // Reporting also removes them, so the tutor isn't left in a channel
        // with someone they flagged.
        blockUser(peer)
    }

    /// Check if a user is blocked (safe from any thread)
    /// - Parameter peerID: The peer ID to check
    /// - Returns: True if the peer is blocked
    func isUserBlocked(_ peerID: String) -> Bool {
        blockLock.lock()
        defer { blockLock.unlock() }
        return blockedUserIDs.contains(peerID)
    }

    // MARK: - Private Methods

    private func stopServices() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
    }

    /// Starts the microphone/playback engine. On failure the channel is ended
    /// with an error (so the UI never shows "Live" with no audio).
    @discardableResult
    private func startAudioManager() -> Bool {
        if audioStreamManager == nil {
            audioStreamManager = AudioStreamManager()
            audioStreamManager?.delegate = self
        }
        // A mute chosen before the engine existed (while "Searching") must
        // apply from the first captured buffer.
        audioStreamManager?.setMuted(isMuted)
        do {
            try audioStreamManager?.startCapturing()
        } catch {
            endSession(state: .error("Couldn't start the microphone: \(error.localizedDescription)"))
            return false
        }
        isAudioActive = true
        startLevelDecayTimer()
        return true
    }

    /// Level callbacks only arrive while audio is flowing, so the meters froze
    /// at their last value when someone stopped talking. Let them fall to 0.
    private func startLevelDecayTimer() {
        guard levelDecayTimer == nil else { return }
        levelDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            if self.localAudioLevel != 0, now.timeIntervalSince(self.lastLocalLevelDate) > 0.4 {
                self.localAudioLevel = 0
            }
            for (peer, date) in self.lastPeerLevelDates where now.timeIntervalSince(date) > 0.4 {
                if (self.peerAudioLevels[peer] ?? 0) != 0 { self.peerAudioLevels[peer] = 0 }
            }
        }
    }

    private func updateConnectedPeers() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.role != .none else { return }
            // Blocked peers are hidden even if Multipeer still has them connected.
            self.connectedPeers = self.session.connectedPeers
                .filter { !self.isUserBlocked($0.displayName) }
                .map { VoiceChannelPeer(peerID: $0) }

            let ids = Set(self.connectedPeers.map(\.id))
            self.peerAudioLevels = self.peerAudioLevels.filter { ids.contains($0.key) }
            self.lastPeerLevelDates = self.lastPeerLevelDates.filter { ids.contains($0.key) }

            if self.connectedPeers.isEmpty {
                guard case .connected = self.state else { return }
                if self.role == .host {
                    // Still advertising: back to waiting, with the same code.
                    self.state = .hosting(code: self.sessionCode)
                } else {
                    // The host ended the channel (or went out of range). Turn
                    // the microphone and the browser off instead of leaving
                    // them running behind an idle screen.
                    self.endSession(notice: "The voice channel ended.")
                }
            } else {
                self.joinTimeoutWork?.cancel()
                self.joinTimeoutWork = nil
                self.state = .connected(peerCount: self.connectedPeers.count)
            }
        }
    }
}

// MARK: - MCSessionDelegate
extension VoiceChannelManager: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        print("👤 Peer \(peerID.displayName) state changed: \(state.rawValue)")
        let name = peerID.displayName

        DispatchQueue.main.async { [weak self] in
            guard let self, self.role != .none else { return }
            if state == .connected {
                guard self.startAudioManager() else { return }
            } else if state == .notConnected {
                self.audioStreamManager?.removePeer(name)
            }
            self.updateConnectedPeers()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let name = peerID.displayName

        if data == Self.removalMessage {
            DispatchQueue.main.async { [weak self] in
                // Only the host we joined may remove us.
                guard let self, self.role == .joiner, name == self.hostPeerName else { return }
                self.endSession(notice: "The host removed you from the voice channel.")
            }
            return
        }

        // Never play audio from a blocked peer.
        guard !isUserBlocked(name) else { return }
        audioStreamManager?.playReceivedData(data, fromPeer: name)
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

        // Only admit peers who joined with this channel's code. Previously any
        // nearby device could connect regardless of the code shown to students.
        guard let context, String(data: context, encoding: .utf8) == sessionCode else {
            print("Peer \(peerID.displayName) joined without the right code, rejecting invitation")
            invitationHandler(false, nil)
            return
        }

        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in
            // endSession also stops the microphone that hosting had started.
            self?.endSession(state: .error("Couldn't host a channel: \(error.localizedDescription) Check that Local Network access is allowed for ClapsBoard in Settings."))
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension VoiceChannelManager: MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let code = info?["code"], code == targetSessionCode, !code.isEmpty else { return }
        // Don't join a host this device has blocked.
        guard !isUserBlocked(peerID.displayName) else { return }
        let name = peerID.displayName
        DispatchQueue.main.async { [weak self] in self?.hostPeerName = name }
        browser.invitePeer(peerID, to: session, withContext: code.data(using: .utf8), timeout: 30)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.endSession(state: .error("Couldn't search for the channel: \(error.localizedDescription) Check that Local Network access is allowed for ClapsBoard in Settings."))
        }
    }
}

// MARK: - AudioStreamManagerDelegate
extension VoiceChannelManager: AudioStreamManagerDelegate {

    func audioStreamManager(_ manager: AudioStreamManager, didCaptureAudioData data: Data) {
        // Send audio to connected peers, except any this device has blocked.
        let targets = session.connectedPeers.filter { !isUserBlocked($0.displayName) }
        guard !targets.isEmpty else { return }

        do {
            // Use .unreliable for audio packet transmission (standard for VoIP)
            try session.send(data, toPeers: targets, with: .unreliable)
        } catch {
            print("❌ Failed to send audio: \(error)")
        }
    }

    func audioStreamManager(_ manager: AudioStreamManager, didUpdateLocalAudioLevel level: Float) {
        DispatchQueue.main.async {
            guard self.state.isActive else { return }
            self.localAudioLevel = self.isMuted ? 0 : level
            self.lastLocalLevelDate = Date()
        }
    }

    func audioStreamManager(_ manager: AudioStreamManager, didUpdateRemoteAudioLevel level: Float, forPeer peerID: String) {
        DispatchQueue.main.async {
            guard self.state.isActive else { return }
            self.peerAudioLevels[peerID] = level
            self.lastPeerLevelDates[peerID] = Date()
        }
    }

    func audioStreamManager(_ manager: AudioStreamManager, didChangeRunning isRunning: Bool, message: String?) {
        DispatchQueue.main.async {
            guard self.state.isActive else { return }
            if let message {
                // The engine could not be restarted: end the channel and say why.
                self.endSession(state: .error(message))
            } else {
                // Paused by an interruption (e.g. a phone call) or resumed after one.
                self.isAudioActive = isRunning
                if !isRunning { self.localAudioLevel = 0 }
            }
        }
    }
}
