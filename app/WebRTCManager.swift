//
//  WebRTCManager.swift
//  App
//
//  Created by Janardhan on 2026-03-22.
//

import WebRTC
import AVFoundation

final class WebRTCManager: NSObject {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    
    private var videoSource: RTCVideoSource!
    private var videoTrack: RTCVideoTrack!
    private var audioTrack: RTCAudioTrack!
    
    override init() {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory()
        super.init()
    }
}
