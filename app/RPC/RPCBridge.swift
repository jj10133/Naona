// RPC/RPCBridge.swift
// Uses raw IPC protocol — no bare-rpc dependency on Swift side.

import BareKit
import Foundation

enum RPCCommand: UInt8 {
    case start       = 1
    case stop        = 2
    case mute        = 3
    case peerJoined  = 10
    case peerLeft    = 11
    case peerControl = 12
    case videoFrame  = 13
    case audioFrame  = 14
}

protocol RPCBridgeDelegate: AnyObject {
    func bridge(_ bridge: RPCBridge, peerJoined peerId: String)
    func bridge(_ bridge: RPCBridge, peerLeft peerId: String)
    func bridge(_ bridge: RPCBridge, peerControl peerId: String, event: [String: Any])
    func bridge(_ bridge: RPCBridge, didReceiveVideo frame: VideoFrame)
    func bridge(_ bridge: RPCBridge, didReceiveAudio frame: AudioFrame)
    func bridge(_ bridge: RPCBridge, didFail error: String)
}

final class RPCBridge {

    weak var delegate: RPCBridgeDelegate?

    private let transport: RPCTransport
    private var startContinuation: CheckedContinuation<Void, Error>?

    init(ipc: IPC) {
        self.transport = RPCTransport(ipc: ipc)
        transport.onMessage = { [weak self] command, data in
            self?.handleMessage(command: command, data: data)
        }
    }

    func start() { transport.start() }
    func stop()  { transport.stop()  }

    // MARK: - Swift → JS

    func sendStart(topic: String, mode: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "topic": topic, "mode": mode
        ])
        return try await withCheckedThrowingContinuation { continuation in
            self.startContinuation = continuation
            self.transport.send(command: RPCCommand.start.rawValue, data: payload)
        }
    }

    func sendStop() {
        transport.send(command: RPCCommand.stop.rawValue)
    }

    func sendMute(video: Bool, audio: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "video": video, "audio": audio
        ]) else { return }
        transport.send(command: RPCCommand.mute.rawValue, data: data)
    }

    // MARK: - JS → Swift

    private func handleMessage(command: UInt8, data: Data) {
        guard let cmd = RPCCommand(rawValue: command) else {
            print("[RPCBridge] unknown command: \(command)")
            return
        }
        print("[RPCBridge] rx cmd:\(command) bytes:\(data.count)")

        switch cmd {
        case .start:
            // Reply to sendStart continuation
            if let json = parseJSON(data) {
                if let error = json["error"] as? String {
                    startContinuation?.resume(throwing: RPCError.startFailed(error))
                } else {
                    startContinuation?.resume()
                }
                startContinuation = nil
            }

        case .peerJoined:
            guard let json   = parseJSON(data),
                  let peerId = json["peerId"] as? String else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.bridge(self, peerJoined: peerId)
            }

        case .peerLeft:
            guard let json   = parseJSON(data),
                  let peerId = json["peerId"] as? String else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.bridge(self, peerLeft: peerId)
            }

        case .peerControl:
            guard let json   = parseJSON(data),
                  let peerId = json["peerId"] as? String else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.bridge(self, peerControl: peerId, event: json)
            }

        case .videoFrame:
            let (video, _) = MediaProtocol.parse(data)
            guard let frame = video else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.bridge(self, didReceiveVideo: frame)
            }

        case .audioFrame:
            let (_, audio) = MediaProtocol.parse(data)
            guard let frame = audio else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.bridge(self, didReceiveAudio: frame)
            }

        default:
            break
        }
    }

    private func parseJSON(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum RPCError: LocalizedError {
    case startFailed(String)
    var errorDescription: String? {
        switch self { case .startFailed(let m): return m }
    }
}
