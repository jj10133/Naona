// WebRTCManager.swift
// Manages one RTCPeerConnection.
// Used in two modes:
//   1. "local" — owns camera/mic capture, no peer connection
//   2. "peer"  — receives shared audio/video tracks, manages one RTCPeerConnection
//
// Signaling callbacks are closures rather than a delegate so multiple instances
// can coexist cleanly (one per remote peer in a mesh call).

import WebRTC
import AVFoundation

final class WebRTCManager: NSObject {

    // MARK: - Signaling callbacks (set by CallViewModel per peer)

    var onLocalSDP:        ((RTCSessionDescription) -> Void)?
    var onLocalCandidate:  ((RTCIceCandidate) -> Void)?
    var onConnectionState: ((RTCIceConnectionState) -> Void)?
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?

    // MARK: - Public tracks

    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var localAudioTrack: RTCAudioTrack?

    // MARK: - Private

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCCameraVideoCapturer?

    override init() {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        super.init()
    }

    deinit {
        RTCCleanupSSL()
    }

    // MARK: - Mode 1: local media only (no peer connection)

    func setup() {
        buildAudioTrack()
        buildVideoTrack()
    }

    // MARK: - Mode 2: peer connection using externally supplied tracks

    func setupWithSharedTracks(audioTrack: RTCAudioTrack?, videoTrack: RTCVideoTrack?) {
        buildPeerConnection()
        let streamIds = ["shared"]
        if let a = audioTrack { peerConnection?.add(a, streamIds: streamIds) }
        if let v = videoTrack { peerConnection?.add(v, streamIds: streamIds) }
    }

    // MARK: - Camera capture

    func startCapture(position: AVCaptureDevice.Position = .front, fps: Int = 30) {
        guard let capturer = videoCapturer else { return }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else { return }
        let format = preferredFormat(for: device, maxWidth: 1280, maxHeight: 720)
        let targetFPS = preferredFPS(for: format, targetFPS: fps)
        capturer.startCapture(with: device, format: format, fps: targetFPS)
    }

    func stopCapture() { videoCapturer?.stopCapture() }

    // MARK: - Offer / Answer

    func makeOffer() {
        let constraints = offerConstraints()
        peerConnection?.offer(for: constraints) { [weak self] sdp, error in
            guard let self, let sdp else { return }
            self.peerConnection?.setLocalDescription(sdp) { error in
                if error == nil { self.onLocalSDP?(sdp) }
            }
        }
    }

    func handleRemoteOffer(_ sdpString: String) {
        let sdp = RTCSessionDescription(type: .offer, sdp: sdpString)
        peerConnection?.setRemoteDescription(sdp) { [weak self] error in
            guard let self, error == nil else { return }
            self.makeAnswer()
        }
    }

    func handleRemoteAnswer(_ sdpString: String) {
        let sdp = RTCSessionDescription(type: .answer, sdp: sdpString)
        peerConnection?.setRemoteDescription(sdp) { error in
            if let error { print("[RTC] set remote answer error: \(error)") }
        }
    }

    func addRemoteCandidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
        let c = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        peerConnection?.add(c) { error in
            if let error { print("[RTC] add candidate error: \(error)") }
        }
    }

    // MARK: - Mute / Video

    var isAudioMuted:  Bool = false { didSet { localAudioTrack?.isEnabled = !isAudioMuted } }
    var isVideoEnabled: Bool = true { didSet { localVideoTrack?.isEnabled = isVideoEnabled } }

    // MARK: - Teardown

    func close() {
        stopCapture()
        peerConnection?.close()
        peerConnection = nil
    }

    // MARK: - Private builders

    private func buildPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = []                     // host candidates only — Hyperswarm provides routing
        config.bundlePolicy  = .maxBundle
        config.rtcpMuxPolicy = .require
        config.sdpSemantics  = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }

    private func buildAudioTrack() {
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        localAudioTrack = factory.audioTrack(with: source, trackId: "audio0")
    }

    private func buildVideoTrack() {
        let source = factory.videoSource()
        videoSource = source
        let capturer = RTCCameraVideoCapturer(delegate: source)
        videoCapturer = capturer
        localVideoTrack = factory.videoTrack(with: source, trackId: "video0")
    }

    private func makeAnswer() {
        peerConnection?.answer(for: offerConstraints()) { [weak self] sdp, error in
            guard let self, let sdp else { return }
            self.peerConnection?.setLocalDescription(sdp) { error in
                if error == nil { self.onLocalSDP?(sdp) }
            }
        }
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

    private func preferredFormat(for device: AVCaptureDevice, maxWidth: Int32, maxHeight: Int32) -> AVCaptureDevice.Format {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        var best = formats.first!
        for f in formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            if d.width <= maxWidth && d.height <= maxHeight {
                let bd = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
                if d.width * d.height > bd.width * bd.height { best = f }
            }
        }
        return best
    }

    private func preferredFPS(for format: AVCaptureDevice.Format, targetFPS: Int) -> Int {
        format.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }.max().map { min(targetFPS, $0) } ?? targetFPS
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
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async { self.onRemoteVideoTrack?(track) }
    }
}
