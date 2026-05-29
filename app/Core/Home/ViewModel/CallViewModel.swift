import SwiftUI
import AVFoundation
import BareKit

@MainActor
final class CallViewModel: ObservableObject {

    @Published var callState:       CallState  = .idle
    @Published var peers:           [PeerSession] = []
    @Published var isAudioMuted     = false
    @Published var isVideoEnabled   = true
    @Published var participantCount = 1

    var onCallEnded: (() -> Void)?

    private(set) var role:    CallRole = .guest
    private let bridge:       BareKitBridge
    private let capture:      MediaCapture

    var previewLayer: AVCaptureVideoPreviewLayer? { capture.makePreviewLayer() }

    init(ipc: IPC) {
        self.bridge  = BareKitBridge(ipc: ipc)
        self.capture = MediaCapture()
        bridge.delegate  = self
        capture.delegate = self
        bridge.startListening()
    }

    func startCall(topic: String, role: CallRole) {
        self.role = role
        callState = .connecting
        capture.start(position: .front)
        bridge.sendCall(topic: topic, role: role)
        bridge.sendMuteState(audio: false, video: false)
    }

    func hangup() {
        bridge.sendHangup()
        bridge.stopListening()
        capture.stop()
        peers.forEach { $0.stop() }
        peers.removeAll()
        callState = .idle
        onCallEnded?()
    }

    func toggleMute() {
        isAudioMuted.toggle()
        capture.isAudioMuted = isAudioMuted
        bridge.sendMuteState(audio: isAudioMuted, video: !isVideoEnabled)
    }

    func toggleVideo() {
        isVideoEnabled.toggle()
        capture.isVideoMuted = !isVideoEnabled
        bridge.sendMuteState(audio: isAudioMuted, video: !isVideoEnabled)
    }

    private func session(for peerId: String) -> PeerSession? {
        peers.first { $0.id == peerId }
    }

    private func removePeer(_ peerId: String) {
        session(for: peerId)?.stop()
        peers.removeAll { $0.id == peerId }
        if role == .guest && peers.isEmpty && callState != .idle {
            callState = .disconnected
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                onCallEnded?()
            }
        }
    }
}

extension CallViewModel: BareKitBridgeDelegate {

    nonisolated func bridge(_ bridge: BareKitBridge, didReceive message: BridgeMessage) {
        Task { @MainActor in
            switch message {

            case .peerJoined(let peerId):
                guard session(for: peerId) == nil else { return }
                peers.append(PeerSession(peerId: peerId))
                if callState != .connected { callState = .connected }

            case .peerLeft(let peerId):
                if role == .guest {
                    capture.stop()
                    peers.forEach { $0.stop() }
                    peers.removeAll()
                    callState = .disconnected
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        onCallEnded?()
                    }
                } else {
                    removePeer(peerId)
                }

            case .videoFrame(let peerId, let data):
                session(for: peerId)?.renderer.receiveVideo(data)

            case .audioFrame(let peerId, let data, let sr, let ch):
                if let renderer = session(for: peerId)?.renderer {
                    renderer.aacSampleRate = sr
                    renderer.aacChannels   = ch
                    renderer.receiveAudio(data)
                }

            case .peerMute(let peerId, let audio, let video):
                if let peer = session(for: peerId) {
                    peer.isAudioMuted          = audio
                    peer.isVideoMuted          = video
                    peer.renderer.isAudioMuted = audio
                    peer.renderer.isVideoMuted = video
                }

            case .participantCount(let count):
                participantCount = count

            case .hangup:
                capture.stop()
                peers.forEach { $0.stop() }
                peers.removeAll()
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

extension CallViewModel: MediaCaptureDelegate {

    nonisolated func capture(_ capture: MediaCapture, didEncodeVideo data: Data) {
        Task { @MainActor in self.bridge.sendVideoFrame(data) }
    }

    nonisolated func capture(_ capture: MediaCapture, didEncodeAudio data: Data) {
        let sr = capture.encodedSampleRate
        let ch = capture.encodedChannels
        Task { @MainActor in self.bridge.sendAudioFrame(data, sampleRate: sr, channels: ch) }
    }
}
