// RPC/RPCBridge.swift

import BareKit
import BareRPC
import Foundation

enum RPCCommand: UInt {
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
    private var rpc: RPC { transport.rpc }

    init(ipc: IPC) {
        self.transport = RPCTransport(ipc: ipc)
        transport.rpc.onEvent = { [weak self] event in
            await self?.handleEvent(event)
        }
        transport.rpc.onError = { err in
            print("[RPCBridge] error: \(err)")
        }
    }

    func start() { transport.start() }
    func stop()  { transport.stop()  }

    // MARK: - Swift → JS

    func sendStart(topic: String, mode: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "topic": topic, "mode": mode
        ])
        // Fire-and-forget style start — just check it doesn't throw
        _ = try await rpc.request(RPCCommand.start.rawValue, data: payload)
    }

    func sendStop() {
        rpc.event(RPCCommand.stop.rawValue)
    }

    func sendMute(video: Bool, audio: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "video": video, "audio": audio
        ]) else { return }
        rpc.event(RPCCommand.mute.rawValue, data: data)
    }

    // MARK: - JS → Swift

    private func handleEvent(_ event: IncomingEvent) async {
        print("[RPCBridge] event command:", event.command, "dataLen:", event.data?.count ?? 0)
        guard let cmd = RPCCommand(rawValue: event.command) else {
            print("[RPCBridge] unknown command:", event.command)
            return
        }

        switch cmd {
        case .peerJoined:
            guard let json   = parseJSON(event.data),
                  let peerId = json["peerId"] as? String else {
                print("[RPCBridge] peerJoined parse failed, data:", event.data.map { String(data: $0, encoding: .utf8) ?? "?" } ?? "nil")
                return
            }
            print("[RPCBridge] peerJoined:", peerId.prefix(8))
            await MainActor.run { delegate?.bridge(self, peerJoined: peerId) }

        case .peerLeft:
            guard let json   = parseJSON(event.data),
                  let peerId = json["peerId"] as? String else { return }
            await MainActor.run { delegate?.bridge(self, peerLeft: peerId) }

        case .peerControl:
            guard let json   = parseJSON(event.data),
                  let peerId = json["peerId"] as? String else { return }
            await MainActor.run { delegate?.bridge(self, peerControl: peerId, event: json) }

        case .videoFrame:
            guard let data = event.data else { return }
            let (video, _) = MediaProtocol.parse(data)
            guard let frame = video else { return }
            await MainActor.run { delegate?.bridge(self, didReceiveVideo: frame) }

        case .audioFrame:
            guard let data = event.data else { return }
            let (_, audio) = MediaProtocol.parse(data)
            guard let frame = audio else { return }
            await MainActor.run { delegate?.bridge(self, didReceiveAudio: frame) }

        default:
            break
        }
    }

    private func parseJSON(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
