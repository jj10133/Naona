// CallViewModel.swift
// SFU architecture:
//
//   Host role:
//     - Connects to every guest via one RTCPeerConnection each
//     - Adds its own local tracks to every peer connection
//     - Receives each guest's remote tracks
//     - Re-publishes each guest's tracks into all OTHER guests' peer connections
//       so everyone sees everyone without direct peer↔peer connections
//
//   Guest role:
//     - Connects to host ONLY via one RTCPeerConnection
//     - Adds its own local tracks to that connection
//     - Receives ALL other participants' tracks from host (host re-publishes them)
//     - Displays each received track as a separate tile
//

import WebRTC
import SwiftUI
import BareKit

// MARK: - CallViewModel

@MainActor
final class CallViewModel: ObservableObject {

    @Published var callState:        CallState    = .idle
    @Published var peers:            [PeerSession] = []
    @Published var isAudioMuted      = false
    @Published var isVideoEnabled    = true
    @Published var isRoomFull        = false
    @Published var participantCount  = 1      // total in call including self

    var onCallEnded: (() -> Void)?
    var localVideoTrack: RTCVideoTrack? { localRTC.localVideoTrack }

    // Shared local media — one camera/mic for all peer connections
    private let localRTC = WebRTCManager()
    private let bridge:   BareKitBridge

    private(set) var role: CallRole = .guest

    // Host only: tracks received from each guest, keyed by peerId
    // Used to re-publish into new guests' peer connections
    private var guestTracks: [String: (audio: RTCAudioTrack?, video: RTCVideoTrack?)] = [:]

    init(ipc: IPC) {
        self.bridge = BareKitBridge(ipc: ipc)
        bridge.delegate = self
        bridge.startListening()
    }

    // MARK: - Start

    func startCall(topic: String, role: CallRole) {
        self.role = role
        callState = .connecting

        localRTC.setup()
        localRTC.startCapture(position: .front)
        bridge.sendCall(topic: topic, role: role)
    }

    // MARK: - Hangup

    func hangup() {
        bridge.sendHangup()
        bridge.stopListening()
        teardownAll()
        callState = .idle
        onCallEnded?()
    }

    // MARK: - Controls

    func toggleMute() {
        isAudioMuted.toggle()
        localRTC.isAudioMuted = isAudioMuted
    }

    func toggleVideo() {
        isVideoEnabled.toggle()
        localRTC.isVideoEnabled = isVideoEnabled
    }

    // MARK: - Private helpers

    private func session(for peerId: String) -> PeerSession? {
        peers.first { $0.id == peerId }
    }

    private func makeSession(peerId: String, isCaller: Bool) -> PeerSession {
        let session = PeerSession(peerId: peerId)

        // ── Tracks to add ─────────────────────────────────────────────────
        // Always add our own local tracks.
        // Host additionally re-publishes each existing guest's tracks into
        // the new connection so the new guest sees everyone already in the call.
        var extraVideoTracks: [RTCVideoTrack] = []
        var extraAudioTracks: [RTCAudioTrack] = []

        if role == .host {
            for (existingPeerId, tracks) in guestTracks where existingPeerId != peerId {
                if let v = tracks.video { extraVideoTracks.append(v) }
                if let a = tracks.audio { extraAudioTracks.append(a) }
            }
        }

        session.rtc.setupWithSharedTracks(
            audioTrack:       localRTC.localAudioTrack,
            videoTrack:       localRTC.localVideoTrack,
            extraAudioTracks: extraAudioTracks,
            extraVideoTracks: extraVideoTracks
        )

        // Adaptive bitrate — reduce quality as participant count grows
        session.rtc.targetBitrate = targetBitrate(for: participantCount)

        // ── Signaling callbacks ───────────────────────────────────────────
        session.rtc.onLocalSDP = { [weak self] sdp in
            Task { @MainActor in self?.bridge.sendSDP(sdp, to: peerId) }
        }
        session.rtc.onLocalCandidate = { [weak self] candidate in
            Task { @MainActor in self?.bridge.sendCandidate(candidate, to: peerId) }
        }
        session.rtc.onConnectionState = { [weak self] state in
            Task { @MainActor in
                session.connectionState = state
                self?.updateCallState()
                if state == .failed || state == .disconnected {
                    self?.removePeer(peerId: peerId)
                }
            }
        }

        // Remote video tracks — in host mode, each is a different guest
        // In guest mode, host sends multiple tracks (one per other participant)
        session.rtc.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor in
                // Append track to this session's track list
                session.addRemoteVideoTrack(track)
                // Host: store for re-publishing to future guests
                if self?.role == .host {
                    var existing = self?.guestTracks[peerId] ?? (nil, nil)
                    existing.video = track
                    self?.guestTracks[peerId] = existing
                    // Re-publish new track to all existing guests
                    self?.republishTrack(track, type: .video, from: peerId)
                }
            }
        }
        session.rtc.onRemoteAudioTrack = { [weak self] track in
            Task { @MainActor in
                if self?.role == .host {
                    var existing = self?.guestTracks[peerId] ?? (nil, nil)
                    existing.audio = track
                    self?.guestTracks[peerId] = existing
                    self?.republishTrack(track, type: .audio, from: peerId)
                }
            }
        }

        peers.append(session)
        if isCaller { session.rtc.makeOffer() }
        return session
    }

    // Host: add a newly received track to all OTHER guests' peer connections
    private enum TrackType { case video, audio }
    private func republishTrack(_ track: RTCMediaStreamTrack, type: TrackType, from sourcePeerId: String) {
        guard role == .host else { return }
        for peer in peers where peer.id != sourcePeerId {
            switch type {
            case .video: peer.rtc.addVideoTrack(track as! RTCVideoTrack)
            case .audio: peer.rtc.addAudioTrack(track as! RTCAudioTrack)
            }
        }
    }

    private func removePeer(peerId: String) {
        peers.removeAll { $0.id == peerId }
        guestTracks.removeValue(forKey: peerId)
        updateCallState()
        // Only end call automatically if WE are a guest and lost our only connection (the host)
        // Host never auto-ends — they control the call lifecycle
        if role == .guest && peers.isEmpty && callState != .idle {
            callState = .disconnected
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                onCallEnded?()
            }
        }
    }

    private func updateCallState() {
        guard !peers.isEmpty else { return }
        let anyConnected = peers.contains {
            $0.connectionState == .connected || $0.connectionState == .completed
        }
        callState = anyConnected ? .connected : .connecting
    }

    private func teardownAll() {
        for p in peers { p.rtc.close() }
        peers.removeAll()
        guestTracks.removeAll()
        localRTC.close()
    }

    // Adaptive bitrate: fewer bits per stream as count grows
    private func targetBitrate(for count: Int) -> Int {
        switch count {
        case ...2:  return 1_200_000   // 1-to-1: 1.2 Mbps
        case 3...4: return   500_000   // small group: 500 Kbps
        case 5...6: return   300_000   // medium group: 300 Kbps
        default:    return   150_000   // large group: 150 Kbps
        }
    }

    // Update bitrate on all sessions when count changes
    private func updateBitrateForAll() {
        let bitrate = targetBitrate(for: participantCount)
        for peer in peers { peer.rtc.targetBitrate = bitrate }
    }
}

// MARK: - BareKitBridgeDelegate

extension CallViewModel: BareKitBridgeDelegate {

    nonisolated func bridge(_ bridge: BareKitBridge, didReceive message: BridgeMessage) {
        Task { @MainActor in
            switch message {

            case .peerJoined(let peerId, let isCaller):
                guard session(for: peerId) == nil else { return }
                // In group mode: host always makes the offer, guest never does.
                // Override isCaller based on role to prevent offer glare.
                let effectiveCaller = (role == .host)  // host always makes offer
                print("[VM] peerJoined: \(peerId.prefix(8)) isCaller:\(effectiveCaller) role:\(role)")
                _ = makeSession(peerId: peerId, isCaller: effectiveCaller)

            case .peerLeft(let peerId):
                session(for: peerId)?.rtc.close()
                if role == .guest {
                    // Host left → end the call for everyone
                    teardownAll()
                    callState = .disconnected
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        onCallEnded?()
                    }
                } else {
                    // A guest left → just remove their tile, call continues
                    removePeer(peerId: peerId)
                }

            case .offer(let peerId, let sdp):
                session(for: peerId)?.rtc.handleRemoteOffer(sdp)

            case .answer(let peerId, let sdp):
                session(for: peerId)?.rtc.handleRemoteAnswer(sdp)

            case .candidate(let peerId, let sdp, let mid, let idx):
                session(for: peerId)?.rtc.addRemoteCandidate(sdp: sdp, sdpMid: mid, sdpMLineIndex: idx)

            case .participantCount(let count):
                participantCount = count
                updateBitrateForAll()

            case .roomFull:
                isRoomFull = true
                callState = .failed("Room is full")
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    onCallEnded?()
                }

            case .hangup:
                teardownAll()
                callState = .disconnected
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    onCallEnded?()
                }

            case .error(let msg):
                callState = .failed(msg)
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    onCallEnded?()
                }
            }
        }
    }
}
