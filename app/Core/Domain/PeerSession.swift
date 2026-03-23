//
//  PeerSession.swift
//  App
//
//  Created by Janardhan on 2026-03-22.
//

import SwiftUI
import WebRTC

// MARK: - PeerSession

@MainActor
final class PeerSession: ObservableObject, Identifiable {
    let id: String                           // Hyperswarm public key hex
    let rtc: WebRTCManager
    @Published var remoteVideoTrack: RTCVideoTrack?
    @Published var connectionState: RTCIceConnectionState = .new

    init(peerId: String) {
        self.id = peerId
        self.rtc = WebRTCManager()
    }
}
