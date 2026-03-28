// ViewModel/CallViewModel.swift

import SwiftUI
import AVFoundation
import BareKit

enum CallState: Equatable {
    case idle, connecting, connected, disconnected, failed(String)

    static func == (lhs: CallState, rhs: CallState) -> Bool {
        switch (lhs, rhs) {
        case (.idle,.idle),(.connecting,.connecting),(.connected,.connected),(.disconnected,.disconnected): return true
        case (.failed(let a),.failed(let b)): return a == b
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle:          return "Idle"
        case .connecting:    return "Connecting…"
        case .connected:     return "Connected"
        case .disconnected:  return "Call ended"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    var dotColor: Color {
        switch self {
        case .connected:             return .green
        case .failed,.disconnected:  return .red
        default:                     return .orange
        }
    }

    var isTerminal: Bool {
        switch self { case .disconnected,.failed: return true; default: return false }
    }
}

enum CallMode: String { case one = "one"; case mesh = "mesh" }

@MainActor
final class CallViewModel: ObservableObject {

    @Published var callState:    CallState      = .idle
    @Published var renderers:    [MediaRenderer] = []
    @Published var localRenderer: MediaRenderer?    // own camera preview
    @Published var isAudioMuted  = false
    @Published var isVideoMuted  = false

    var onCallEnded: (() -> Void)?
    private(set) var mode: CallMode = .mesh
    private let bridge: RPCBridge

    init(ipc: IPC) {
        self.bridge     = RPCBridge(ipc: ipc)
        bridge.delegate = self
        bridge.start()
    }

    func startCall(topic: String, mode: CallMode) {
        self.mode = mode
        callState = .connecting
        // Create local renderer immediately — will receive '__local__' frames from JS
        localRenderer = MediaRenderer(peerId: "__local__")
        _requestPermissions {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.bridge.sendStart(topic: topic, mode: mode.rawValue)
                    print("[VM] pipeline started")
                } catch {
                    self.callState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func hangup() {
        bridge.sendStop()
        bridge.stop()
        localRenderer?.stop()
        localRenderer = nil
        _teardown()
        onCallEnded?()
    }

    func toggleMute()  { isAudioMuted.toggle(); bridge.sendMute(video: isVideoMuted, audio: isAudioMuted) }
    func toggleVideo() { isVideoMuted.toggle(); bridge.sendMute(video: isVideoMuted, audio: isAudioMuted) }

    private func renderer(for peerId: String) -> MediaRenderer? {
        renderers.first { $0.id == peerId }
    }

    private func _teardown() {
        renderers.forEach { $0.stop() }
        renderers.removeAll()
        callState = .idle
    }

    private func _requestPermissions(completion: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { completion() }
            }
        }
    }
}

extension CallViewModel: RPCBridgeDelegate {

    nonisolated func bridge(_ bridge: RPCBridge, peerJoined peerId: String) {
        print("[VM] peerJoined delegate called:", peerId.prefix(8))
        Task { @MainActor [weak self] in
            guard let self, self.renderer(for: peerId) == nil else { return }
            print("[VM] creating renderer for:", peerId.prefix(8))
            self.renderers.append(MediaRenderer(peerId: peerId))
            if self.callState != .connected { self.callState = .connected }
            print("[VM] callState now: connected, renderers:", self.renderers.count)
        }
    }

    nonisolated func bridge(_ bridge: RPCBridge, peerLeft peerId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.renderer(for: peerId)?.stop()
            self.renderers.removeAll { $0.id == peerId }
            if self.renderers.isEmpty { self.callState = .connecting }
        }
    }

    nonisolated func bridge(_ bridge: RPCBridge, peerControl peerId: String, event: [String: Any]) {}

    nonisolated func bridge(_ bridge: RPCBridge, didReceiveVideo frame: VideoFrame) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if frame.peerId == "__local__" {
                self.localRenderer?.handleVideo(frame)
            } else {
                if self.renderers.isEmpty {
                    print("[VM] video frame arrived but no renderer yet for:", frame.peerId.prefix(8))
                }
                self.renderer(for: frame.peerId)?.handleVideo(frame)
            }
        }
    }

    nonisolated func bridge(_ bridge: RPCBridge, didReceiveAudio frame: AudioFrame) {
        Task { @MainActor [weak self] in
            self?.renderer(for: frame.peerId)?.handleAudio(frame)
        }
    }

    nonisolated func bridge(_ bridge: RPCBridge, didFail error: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.callState = .failed(error)
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.onCallEnded?() }
        }
    }
}
