// PeerSession.swift
// In guest mode a single peer connection to the host carries
// multiple remote video tracks (one per other participant).
// addRemoteVideoTrack appends each as it arrives.

import SwiftUI
import WebRTC

@MainActor
final class PeerSession: ObservableObject, Identifiable {
    let id:  String          // Hyperswarm public key hex
    let rtc: WebRTCManager

    // Guest mode: host sends N video tracks (one per other participant)
    // Host mode:  each peer connection has exactly one remote track
    @Published var remoteVideoTracks: [RTCVideoTrack] = []
    @Published var connectionState:   RTCIceConnectionState = .new

    // Convenience for 1-to-1 and host-mode display
    var remoteVideoTrack: RTCVideoTrack? { remoteVideoTracks.first }

    init(peerId: String) {
        self.id  = peerId
        self.rtc = WebRTCManager()
    }

    func addRemoteVideoTrack(_ track: RTCVideoTrack) {
        guard !remoteVideoTracks.contains(where: { $0.trackId == track.trackId }) else { return }
        remoteVideoTracks.append(track)
    }
}
