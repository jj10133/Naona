//
//  CallState.swift
//  App
//
//  Created by Janardhan on 2026-03-22.
//


// CallViewModel.swift
// Orchestrates the full call flow:
//   1. User taps "Call" → tell JS to join Hyperswarm topic
//   2. JS signals "ready" → Swift generates WebRTC offer
//   3. Swift sends offer → JS forwards to peer via Hyperswarm
//   4. JS receives peer's answer/candidates → Swift applies them
//   5. WebRTC ICE connects directly using the IPs Hyperswarm exchanged

import WebRTC
import Combine
import SwiftUI

enum CallState {
    case idle
    case connecting        // Hyperswarm peer discovery
    case waitingForAnswer  // offer sent, awaiting answer
    case iceChecking       // ICE connectivity checks
    case connected
    case disconnected
    case failed(String)
}

@MainActor
final class CallViewModel: ObservableObject {

    @Published var callState: CallState = .idle
    @Published var remoteVideoTrack: RTCVideoTrack?
    @Published var isAudioMuted = false
    @Published var isVideoEnabled = true

    // Access local video track for the preview renderer
    var localVideoTrack: RTCVideoTrack? { rtcManager.localVideoTrack }

    private let rtcManager: WebRTCManager
    private let bridge: BareKitBridge
    private let isCaller: Bool

    /// - Parameters:
    ///   - worklet: The already-started BareKit Worklet.
    ///   - isCaller: `true` for the peer who initiates the call.
    init(worklet: Worklet, isCaller: Bool) {
        self.isCaller = isCaller
        self.rtcManager = WebRTCManager()
        self.bridge = BareKitBridge(worklet: worklet)

        rtcManager.delegate = self
        bridge.delegate = self
    }

    // MARK: - Call Lifecycle

    /// Start call flow. `topic` is the shared 32-byte hex Hyperswarm discovery key.
    func startCall(topic: String) {
        callState = .connecting
        rtcManager.setup()
        rtcManager.startCapture(position: .front)
        bridge.sendCall(topic: topic)
        // WebRTC offer is generated once JS signals "ready" (peer found on Hyperswarm)
    }

    func hangup() {
        bridge.sendHangup()
        rtcManager.close()
        callState = .idle
        remoteVideoTrack = nil
    }

    func toggleMute() {
        isAudioMuted.toggle()
        rtcManager.isAudioMuted = isAudioMuted
    }

    func toggleVideo() {
        isVideoEnabled.toggle()
        rtcManager.isVideoEnabled = isVideoEnabled
    }
}

// MARK: - WebRTCManagerDelegate

extension CallViewModel: WebRTCManagerDelegate {

    nonisolated func webRTCManager(_ manager: WebRTCManager,
                                    didGenerateLocalSDP sdp: RTCSessionDescription) {
        Task { @MainActor in
            bridge.sendSDP(sdp)
        }
    }

    nonisolated func webRTCManager(_ manager: WebRTCManager,
                                    didDiscoverLocalCandidate candidate: RTCIceCandidate) {
        Task { @MainActor in
            bridge.sendCandidate(candidate)
        }
    }

    nonisolated func webRTCManager(_ manager: WebRTCManager,
                                    didChangeConnectionState state: RTCIceConnectionState) {
        Task { @MainActor in
            switch state {
            case .checking:
                callState = .iceChecking
            case .connected, .completed:
                callState = .connected
            case .disconnected:
                callState = .disconnected
            case .failed:
                callState = .failed("ICE connection failed")
            default:
                break
            }
        }
    }

    nonisolated func webRTCManager(_ manager: WebRTCManager,
                                    didReceiveRemoteVideoTrack track: RTCVideoTrack) {
        Task { @MainActor in
            remoteVideoTrack = track
        }
    }
}

// MARK: - BareKitBridgeDelegate

extension CallViewModel: BareKitBridgeDelegate {

    nonisolated func bridge(_ bridge: BareKitBridge, didReceive message: BridgeMessage) {
        Task { @MainActor in
            switch message {

            case .ready:
                // Hyperswarm stream is open. Caller makes the offer; callee waits.
                if isCaller {
                    rtcManager.makeOffer()
                }

            case .offer(let sdp):
                // Callee receives offer from caller.
                rtcManager.handleRemoteOffer(sdp)

            case .answer(let sdp):
                // Caller receives answer from callee.
                rtcManager.handleRemoteAnswer(sdp)

            case .candidate(let sdp, let mid, let idx):
                rtcManager.addRemoteCandidate(sdp: sdp, sdpMid: mid, sdpMLineIndex: idx)

            case .hangup:
                rtcManager.close()
                callState = .idle
                remoteVideoTrack = nil

            case .error(let msg):
                callState = .failed(msg)
            }
        }
    }
}