//
//  VoiceChannelView.swift
//  ClapsBoard
//

import SwiftUI

/// Voice Channel main view with premium UX
struct VoiceChannelView: View {
    @StateObject private var voiceManager = VoiceChannelManager()
    @State private var joinCode = ""
    @FocusState private var isCodeFocused: Bool
    
    // Haptics
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let select = UISelectionFeedbackGenerator()
    
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 32) {
                    headerSection
                    
                    if voiceManager.state.isActive {
                        ActiveSessionCard(voiceManager: voiceManager)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    } else {
                        actionSection
                            .transition(.opacity)
                    }
                    
                    infoSection
                }
                .padding(.vertical, 24)
            }
        }
        .navigationTitle("Voice Channel")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: voiceManager.state.isActive)
        .onAppear {
            impact.prepare()
            select.prepare()
        }
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                // Background waveform animation
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color.green.opacity(0.2))
                        .scaleEffect(1.0 + CGFloat(i) * 0.2)
                        .opacity(voiceManager.state.isActive ? 1.0 : 0.0)
                }
                
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(LinearGradient(colors: [.green, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .green.opacity(0.3), radius: 10, x: 0, y: 5)
            }
            .padding(.bottom, 8)
            
            Text("Voice Channel")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            
            Text("Crystal clear voice for your lessons")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    private var actionSection: some View {
        VStack(spacing: 24) {
            // Host Button
            Button(action: { 
                impact.impactOccurred()
                voiceManager.hostChannel() 
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.headline)
                    Text("Host New Channel")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.green)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .green.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            
            HStack {
                Rectangle().frame(height: 1).foregroundStyle(Color.gray.opacity(0.3))
                Text("OR JOIN").font(.caption2).fontWeight(.bold).foregroundStyle(.secondary).padding(.horizontal, 8)
                Rectangle().frame(height: 1).foregroundStyle(Color.gray.opacity(0.3))
            }
            
            // Join Section
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    TextField("Code", text: $joinCode)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .focused($isCodeFocused)
                        .onChange(of: joinCode) { newValue in
                            if newValue.count > 0 { select.selectionChanged() }
                            if newValue.count > 4 { joinCode = String(newValue.prefix(4)) }
                        }
                    
                    Button(action: {
                        impact.impactOccurred()
                        voiceManager.joinChannel(code: joinCode)
                    }) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 20, weight: .bold))
                            .frame(width: 60, height: 60)
                            .background(joinCode.count == 4 ? Color.blue : Color.gray.opacity(0.3))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: joinCode.count == 4 ? .blue.opacity(0.3) : .clear, radius: 5, x: 0, y: 3)
                    }
                    .disabled(joinCode.count != 4)
                }
            }
        }
        .padding(.horizontal, 24)
    }
    
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("HIGHLIGHTS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            
            VStack(spacing: 1) {
                InfoItem(icon: "bolt.fill", color: .orange, title: "Low Latency", subtitle: "Real-time communication with peer-to-peer technology.")
                Divider().padding(.leading, 50)
                InfoItem(icon: "lock.fill", color: .blue, title: "Secure", subtitle: "End-to-end encrypted connection on your local network.")
                Divider().padding(.leading, 50)
                InfoItem(icon: "speaker.wave.3.fill", color: .green, title: "Spatial Audio", subtitle: "Optimized for clear voice chat during tutoring.")
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Active Session Card
struct ActiveSessionCard: View {
    @ObservedObject var voiceManager: VoiceChannelManager
    @State private var pulseScale: CGFloat = 1.0
    
    var body: some View {
        VStack(spacing: 28) {
            // Status Info
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .opacity(pulseScale)
                    
                    Text(statusTitle.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(statusColor)
                }
                
                if case .hosting(let code) = voiceManager.state {
                    Text(code)
                        .font(.system(size: 54, weight: .black, design: .monospaced))
                        .foregroundStyle(.primary)
                } else if case .connected = voiceManager.state {
                    Text("Connected")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                }
            }
            
            // Visualizer & Control
            ZStack {
                // Background pulsing ring for audio level
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 120 + CGFloat(voiceManager.localAudioLevel * 60), 
                           height: 120 + CGFloat(voiceManager.localAudioLevel * 60))
                    .animation(.interactiveSpring(), value: voiceManager.localAudioLevel)
                
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 140 + CGFloat(voiceManager.localAudioLevel * 100), 
                           height: 140 + CGFloat(voiceManager.localAudioLevel * 100))
                    .animation(.interactiveSpring(), value: voiceManager.localAudioLevel)

                Button(action: { 
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    voiceManager.toggleMute() 
                }) {
                    ZStack {
                        Circle()
                            .fill(voiceManager.isMuted ? Color.red : Color.green)
                            .frame(width: 100, height: 100)
                            .shadow(color: (voiceManager.isMuted ? Color.red : Color.green).opacity(0.4), radius: 10, x: 0, y: 5)
                        
                        Image(systemName: voiceManager.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(height: 240)
            
            // Peer List
            if !voiceManager.connectedPeers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("STUDENTS CONNECTED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 0) {
                        ForEach(voiceManager.connectedPeers) { peer in
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.blue.opacity(0.1)).frame(width: 40, height: 40)
                                    Image(systemName: "person.fill").foregroundStyle(.blue)

                                    // Remote audio indicator
                                    Circle()
                                        .stroke(Color.green, lineWidth: 2)
                                        .frame(width: 44, height: 44)
                                        .scaleEffect(1.0 + CGFloat(voiceManager.remoteAudioLevel * 0.3))
                                        .opacity(Double(voiceManager.remoteAudioLevel))
                                }

                                Text(peer.displayName)
                                    .fontWeight(.medium)

                                Spacer()

                                if voiceManager.remoteAudioLevel > 0.05 {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .contextMenu {
                                Button(role: .destructive) {
                                    voiceManager.blockUser(peer)
                                } label: {
                                    Label("Block", systemImage: "hand.raised.fill")
                                }

                                Button {
                                    voiceManager.reportUser(peer)
                                } label: {
                                    Label("Report", systemImage: "flag.fill")
                                }
                            }

                            if peer.id != voiceManager.connectedPeers.last?.id {
                                Divider().padding(.leading, 68)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            
            // End Session
            Button(action: { 
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                voiceManager.disconnect() 
            }) {
                Text("End Session")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(24)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.05), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 24)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseScale = 0.5
            }
        }
    }
    
    private var statusColor: Color {
        switch voiceManager.state {
        case .hosting: return .orange
        case .joining: return .blue
        case .connected: return .green
        case .error: return .red
        default: return .gray
        }
    }
    
    private var statusTitle: String {
        switch voiceManager.state {
        case .hosting: return "Live · Waiting"
        case .joining: return "Searching"
        case .connected: return "Live · Connected"
        case .error: return "Connection Error"
        default: return "Idle"
        }
    }
}

// MARK: - Components

struct InfoItem: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(color.opacity(0.1)).frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(color).font(.system(size: 16, weight: .bold))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.bold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
