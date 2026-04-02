// WebRTCManager.swift
// Manages one RTCPeerConnection.
// Extended for SFU: can re-publish remote tracks from other guests,
// supports adaptive bitrate, and exposes onRemoteAudioTrack callback.

import WebRTC
import AVFoundation

final class WebRTCManager: NSObject {

    // MARK: - Signaling callbacks

    var onLocalSDP:         ((RTCSessionDescription) -> Void)?
    var onLocalCandidate:   ((RTCIceCandidate) -> Void)?
    var onConnectionState:  ((RTCIceConnectionState) -> Void)?
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?
    var onRemoteAudioTrack: ((RTCAudioTrack) -> Void)?

    // MARK: - Adaptive bitrate (bps). Set before makeOffer/Answer.

    var targetBitrate: Int = 1_200_000

    // MARK: - Public tracks

    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var localAudioTrack: RTCAudioTrack?

    // MARK: - Private

    private let factory:           RTCPeerConnectionFactory
    private var peerConnection:    RTCPeerConnection?
    private var videoSource:       RTCVideoSource?
    private var videoCapturer:     RTCCameraVideoCapturer?
    private var pendingCandidates: [RTCIceCandidate] = []  // buffered until remote desc is set
    private var hasRemoteDesc      = false
    private var isSettingUp        = false  // suppress renegotiation during initial track setup

    override init() {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        super.init()
    }

    deinit { RTCCleanupSSL() }

    // MARK: - Mode 1: local media only

    func setup() {
        buildAudioTrack()
        buildVideoTrack()
    }

    // MARK: - Mode 2: peer connection with shared + extra tracks
    // extraAudioTracks / extraVideoTracks = other guests' tracks re-published by host

    func setupWithSharedTracks(
        audioTrack:       RTCAudioTrack?,
        videoTrack:       RTCVideoTrack?,
        extraAudioTracks: [RTCAudioTrack] = [],
        extraVideoTracks: [RTCVideoTrack] = []
    ) {
        isSettingUp = true
        buildPeerConnection()
        let streamIds = ["local"]
        if let a = audioTrack { peerConnection?.add(a, streamIds: streamIds) }
        if let v = videoTrack { peerConnection?.add(v, streamIds: streamIds) }

        // Re-published tracks from other guests (host SFU use case)
        for (i, a) in extraAudioTracks.enumerated() {
            peerConnection?.add(a, streamIds: ["guest_audio_\(i)"])
        }
        for (i, v) in extraVideoTracks.enumerated() {
            peerConnection?.add(v, streamIds: ["guest_video_\(i)"])
        }
        isSettingUp = false
    }

    // MARK: - Dynamic track addition (host adds new guest track after setup)

    func addVideoTrack(_ track: RTCVideoTrack) {
        peerConnection?.add(track, streamIds: ["guest_\(track.trackId)"])
        _renegotiate()
    }

    func addAudioTrack(_ track: RTCAudioTrack) {
        peerConnection?.add(track, streamIds: ["guest_\(track.trackId)"])
        _renegotiate()
    }

    // MARK: - Camera

    func startCapture(position: AVCaptureDevice.Position = .front, fps: Int = 30) {
        guard let capturer = videoCapturer else { return }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else { return }
        let format    = preferredFormat(for: device, maxWidth: 1280, maxHeight: 720)
        let targetFPS = preferredFPS(for: format, targetFPS: fps)
        capturer.startCapture(with: device, format: format, fps: targetFPS)
    }

    func stopCapture() { videoCapturer?.stopCapture() }

    // MARK: - Offer / Answer

    func makeOffer() {
        print("[RTC] making offer")
        peerConnection?.offer(for: offerConstraints()) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            self.peerConnection?.setLocalDescription(sdp) { error in
                if error == nil {
                    print("[RTC] offer ready, sending")
                    self.onLocalSDP?(sdp)
                }
            }
        }
    }

    func handleRemoteOffer(_ sdpString: String) {
        print("[RTC] handling remote offer")
        let sdp = RTCSessionDescription(type: .offer, sdp: sdpString)
        peerConnection?.setRemoteDescription(sdp) { [weak self] error in
            guard let self, error == nil else {
                print("[RTC] setRemoteDescription (offer) error: \(String(describing: error))")
                return
            }
            self.hasRemoteDesc = true
            self._flushPendingCandidates()
            self.makeAnswer()
        }
    }

    func handleRemoteAnswer(_ sdpString: String) {
        let sdp = RTCSessionDescription(type: .answer, sdp: sdpString)
        peerConnection?.setRemoteDescription(sdp) { [weak self] error in
            if let error { print("[RTC] set remote answer error: \(error)"); return }
            self?.hasRemoteDesc = true
            self?._flushPendingCandidates()
            self?._applyBitrateToSenders()
        }
    }

    func addRemoteCandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
        let c = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        if hasRemoteDesc {
            peerConnection?.add(c) { error in
                if let error { print("[RTC] add candidate error: \(error)") }
            }
        } else {
            // Remote description not set yet — buffer and apply after
            pendingCandidates.append(c)
        }
    }

    // MARK: - Mute / Video

    var isAudioMuted:   Bool = false { didSet { localAudioTrack?.isEnabled = !isAudioMuted } }
    var isVideoEnabled: Bool = true  { didSet { localVideoTrack?.isEnabled  = isVideoEnabled } }

    // MARK: - Teardown

    func close() {
        stopCapture()
        peerConnection?.close()
        peerConnection = nil
        pendingCandidates.removeAll()
        hasRemoteDesc = false
        isSettingUp   = false
    }

    // MARK: - Private builders

    private func buildPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers    = []
        config.bundlePolicy  = .maxBundle
        config.rtcpMuxPolicy = .require
        config.sdpSemantics  = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )
        peerConnection = factory.peerConnection(
            with: config, constraints: constraints, delegate: self
        )
    }

    private func buildAudioTrack() {
        let src = factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil
        ))
        localAudioTrack = factory.audioTrack(with: src, trackId: "audio0")
    }

    private func buildVideoTrack() {
        let src       = factory.videoSource()
        videoSource   = src
        let capturer  = RTCCameraVideoCapturer(delegate: src)
        videoCapturer = capturer
        localVideoTrack = factory.videoTrack(with: src, trackId: "video0")
    }

    private func makeAnswer() {
        peerConnection?.answer(for: offerConstraints()) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            self.peerConnection?.setLocalDescription(sdp) { error in
                if error == nil { self.onLocalSDP?(sdp) }
            }
        }
        _applyBitrateToSenders()
    }

    private func offerConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
            optionalConstraints: nil
        )
    }

    private func _flushPendingCandidates() {
        guard !pendingCandidates.isEmpty else { return }
        print("[RTC] flushing \(pendingCandidates.count) buffered candidates")
        for c in pendingCandidates {
            peerConnection?.add(c) { error in
                if let error { print("[RTC] buffered candidate error: \(error)") }
            }
        }
        pendingCandidates.removeAll()
    }

    // Apply targetBitrate to all video senders
    private func _applyBitrateToSenders() {
        guard let pc = peerConnection else { return }
        for sender in pc.senders {
            guard sender.track?.kind == "video" else { continue }
            let params = sender.parameters
            for encoding in params.encodings {
                encoding.maxBitrateBps = NSNumber(value: targetBitrate)
            }
            sender.parameters = params
        }
    }

    // Trigger renegotiation after adding a track mid-call
    private func _renegotiate() {
        guard !isSettingUp else { return }  // don't renegotiate during initial setup
        guard peerConnection?.signalingState == .stable else { return }
        makeOffer()
    }

    private func preferredFormat(
        for device: AVCaptureDevice, maxWidth: Int32, maxHeight: Int32
    ) -> AVCaptureDevice.Format {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        var best = formats.first!
        for f in formats {
            let d  = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let bd = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            if d.width <= maxWidth && d.height <= maxHeight &&
               d.width * d.height > bd.width * bd.height { best = f }
        }
        return best
    }

    private func preferredFPS(for format: AVCaptureDevice.Format, targetFPS: Int) -> Int {
        format.videoSupportedFrameRateRanges
            .map { Int($0.maxFrameRate) }.max()
            .map { min(targetFPS, $0) } ?? targetFPS
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCManager: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        onConnectionState?(state)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // Unified Plan — remote tracks arrive here
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        DispatchQueue.main.async {
            if let video = rtpReceiver.track as? RTCVideoTrack {
                self.onRemoteVideoTrack?(video)
            } else if let audio = rtpReceiver.track as? RTCAudioTrack {
                self.onRemoteAudioTrack?(audio)
            }
        }
    }
}
