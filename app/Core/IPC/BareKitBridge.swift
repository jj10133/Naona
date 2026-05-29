import BareKit
import AVFoundation
import Foundation

enum CallRole: String {
    case host  = "host"
    case guest = "guest"
}

enum BridgeMessage {
    case peerJoined(peerId: String)
    case peerLeft(peerId: String)
    case videoFrame(peerId: String, data: Data)
    case audioFrame(peerId: String, data: Data)
    case peerMute(peerId: String, audio: Bool, video: Bool)
    case participantCount(Int)
    case hangup
    case error(String)
}

protocol BareKitBridgeDelegate: AnyObject {
    func bridge(_ bridge: BareKitBridge, didReceive message: BridgeMessage)
}

final class BareKitBridge {

    weak var delegate: BareKitBridgeDelegate?

    private let ipc: IPC
    private var readTask: Task<Void, Never>?
    private var lineBuffer = ""

    init(ipc: IPC) { self.ipc = ipc }

    func startListening() {
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await data in self.ipc { self.handleChunk(data) }
            } catch {
                print("[Bridge] read error: \(error)")
            }
        }
    }

    func stopListening() { readTask?.cancel(); readTask = nil }

    private func handleChunk(_ data: Data) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        lineBuffer += str
        let lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.last ?? ""
        for line in lines.dropLast() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            parseAndDeliver(t)
        }
    }

    private func parseAndDeliver(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        let msg: BridgeMessage
        switch type {

        case "peerJoined":
            guard let peerId = json["peerId"] as? String else { return }
            msg = .peerJoined(peerId: peerId)

        case "peerLeft":
            guard let peerId = json["peerId"] as? String else { return }
            msg = .peerLeft(peerId: peerId)

        case "videoFrame":
            guard let peerId = json["peerId"] as? String,
                  let b64    = json["data"]   as? String,
                  let raw    = Data(base64Encoded: b64) else { return }
            msg = .videoFrame(peerId: peerId, data: raw)

        case "audioFrame":
            guard let peerId = json["peerId"] as? String,
                  let b64    = json["data"]   as? String,
                  let raw    = Data(base64Encoded: b64) else { return }
            msg = .audioFrame(peerId: peerId, data: raw)

        case "mute":
            guard let peerId = json["peerId"] as? String else { return }
            msg = .peerMute(peerId: peerId,
                            audio: json["audio"] as? Bool ?? false,
                            video: json["video"] as? Bool ?? false)

        case "participantCount":
            msg = .participantCount(json["count"] as? Int ?? 1)

        case "hangup":
            msg = .hangup

        case "error":
            msg = .error(json["message"] as? String ?? "unknown")

        default:
            return
        }

        DispatchQueue.main.async { self.delegate?.bridge(self, didReceive: msg) }
    }

    func sendCall(topic: String, role: CallRole) {
        send(["type": "call", "topic": topic, "role": role.rawValue])
    }

    func sendVideoFrame(_ data: Data) {
        send(["type": "videoFrame", "data": data.base64EncodedString()])
    }

    func sendAudioFrame(_ data: Data) {
        send(["type": "audioFrame", "data": data.base64EncodedString()])
    }

    func sendMuteState(audio: Bool, video: Bool) {
        send(["type": "muteState", "audio": audio, "video": video])
    }

    func sendHangup() { send(["type": "hangup"]) }

    private func send(_ payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        Task {
            do { try await ipc.write(data: data) }
            catch { print("[Bridge] write error: \(error)") }
        }
    }
}
