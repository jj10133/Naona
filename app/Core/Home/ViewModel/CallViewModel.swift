// CallViewModel.swift
// Each remote peer gets its own WebRTCManager instance.
// PeerSession holds the manager + their remote video track.

import WebRTC
import SwiftUI
import BareKit

// MARK: - CallViewModel

@MainActor
final class CallViewModel: ObservableObject {

    @Published var callState: CallState = .idle
    @Published var peers: [PeerSession] = []       // one entry per remote peer
    @Published var isAudioMuted   = false
    @Published var isVideoEnabled = true
    @Published var isRoomFull     = false

    var onCallEnded: (() -> Void)?
    var localVideoTrack: RTCVideoTrack? { localRTC.localVideoTrack }

    // Shared local media source (one camera/mic, shared across all peer connections)
    private let localRTC = WebRTCManager()
    private let bridge: BareKitBridge
    private(set) var mode: CallMode = .one

    init(ipc: IPC) {
        self.bridge = BareKitBridge(ipc: ipc)
        bridge.delegate = self
        bridge.startListening()
    }

    // MARK: - Start

    func startCall(topic: String, mode: CallMode = .one) {
        self.mode = mode
        callState = .connecting
        localRTC.setup()
        localRTC.startCapture(position: .front)
        bridge.sendCall(topic: topic, mode: mode)
    }

    // MARK: - Hangup

    func hangup() {
        bridge.sendHangup()
        bridge.stopListening()
        teardownAll()
        callState = .idle
        onCallEnded?()
    }

    // MARK: - Controls (affect local tracks shared across all peers)

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

        // Set up the peer connection using the same local media
        session.rtc.setupWithSharedTracks(
            audioTrack: localRTC.localAudioTrack,
            videoTrack: localRTC.localVideoTrack
        )

        // Wire delegate so signaling events route back here tagged with peerId
        session.rtc.onLocalSDP = { [weak self] sdp in
            Task { @MainActor in
                self?.bridge.sendSDP(sdp, to: peerId)
            }
        }
        session.rtc.onLocalCandidate = { [weak self] candidate in
            Task { @MainActor in
                self?.bridge.sendCandidate(candidate, to: peerId)
            }
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
        session.rtc.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor in
                session.remoteVideoTrack = track
            }
        }

        peers.append(session)

        if isCaller { session.rtc.makeOffer() }

        return session
    }

    private func removePeer(peerId: String) {
        peers.removeAll { $0.id == peerId }
        updateCallState()
        if peers.isEmpty && callState != .idle {
            callState = .disconnected
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                onCallEnded?()
            }
        }
    }

    private func updateCallState() {
        guard !peers.isEmpty else { return }
        let anyConnected = peers.contains { $0.connectionState == .connected || $0.connectionState == .completed }
        callState = anyConnected ? .connected : .connecting
    }

    private func teardownAll() {
        for p in peers { p.rtc.close() }
        peers.removeAll()
        localRTC.close()
    }
}

// MARK: - BareKitBridgeDelegate

extension CallViewModel: BareKitBridgeDelegate {

    nonisolated func bridge(_ bridge: BareKitBridge, didReceive message: BridgeMessage) {
        Task { @MainActor in
            switch message {

            case .peerJoined(let peerId, let isCaller):
                guard session(for: peerId) == nil else { return }
                _ = makeSession(peerId: peerId, isCaller: isCaller)

            case .peerLeft(let peerId):
                session(for: peerId)?.rtc.close()
                removePeer(peerId: peerId)

            case .offer(let peerId, let sdp):
                session(for: peerId)?.rtc.handleRemoteOffer(sdp)

            case .answer(let peerId, let sdp):
                session(for: peerId)?.rtc.handleRemoteAnswer(sdp)

            case .candidate(let peerId, let sdp, let mid, let idx):
                session(for: peerId)?.rtc.addRemoteCandidate(sdp: sdp, sdpMid: mid, sdpMLineIndex: idx)

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
