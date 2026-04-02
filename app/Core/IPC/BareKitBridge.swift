// BareKitBridge.swift

import BareKit
import WebRTC
import Foundation

// MARK: - Call role

enum CallRole: String {
    case host  = "host"   // SFU node — connects to all guests
    case guest = "guest"  // Participant — connects only to host
}

// MARK: - Bridge messages

enum BridgeMessage {
    case peerJoined(peerId: String, isCaller: Bool)
    case peerLeft(peerId: String)
    case offer(peerId: String, sdp: String)
    case answer(peerId: String, sdp: String)
    case candidate(peerId: String, sdp: String, sdpMid: String?, sdpMLineIndex: Int32)
    case participantCount(Int)  // total participants including self
    case roomFull
    case hangup
    case error(message: String)
}

protocol BareKitBridgeDelegate: AnyObject {
    func bridge(_ bridge: BareKitBridge, didReceive message: BridgeMessage)
}

// MARK: - BareKitBridge

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
                print("[BareKitBridge] read error: \(error)")
            }
        }
    }

    func stopListening() { readTask?.cancel(); readTask = nil }

    // MARK: - Chunk → line splitting

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
        guard
            let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            print("[BareKitBridge] malformed: \(line.prefix(80))")
            return
        }

        let msg: BridgeMessage
        switch type {

        case "peerJoined":
            guard let peerId = json["peerId"] as? String else { return }
            let isCaller = json["isCaller"] as? Bool ?? false
            msg = .peerJoined(peerId: peerId, isCaller: isCaller)

        case "peerLeft":
            guard let peerId = json["peerId"] as? String else { return }
            msg = .peerLeft(peerId: peerId)

        case "offer":
            guard let peerId = json["peerId"] as? String,
                  let sdp   = json["sdp"]    as? String else { return }
            msg = .offer(peerId: peerId, sdp: sdp)

        case "answer":
            guard let peerId = json["peerId"] as? String,
                  let sdp   = json["sdp"]    as? String else { return }
            msg = .answer(peerId: peerId, sdp: sdp)

        case "candidate":
            guard let peerId = json["peerId"] as? String,
                  let sdp   = json["sdp"]    as? String else { return }
            let mid = json["sdpMid"] as? String
            let idx = (json["sdpMLineIndex"] as? Int).map(Int32.init) ?? 0
            msg = .candidate(peerId: peerId, sdp: sdp, sdpMid: mid, sdpMLineIndex: idx)

        case "participantCount":
            let count = json["count"] as? Int ?? 1
            msg = .participantCount(count)

        case "roomFull":
            msg = .roomFull

        case "hangup":
            msg = .hangup

        case "error":
            msg = .error(message: json["message"] as? String ?? "unknown")

        default:
            print("[BareKitBridge] unknown type: \(type)")
            return
        }

        DispatchQueue.main.async { self.delegate?.bridge(self, didReceive: msg) }
    }

    // MARK: - Swift → JS

    func sendCall(topic: String, role: CallRole) {
        send(["type": "call", "topic": topic, "mode": "group", "role": role.rawValue])
    }

    func sendSDP(_ sdp: RTCSessionDescription, to peerId: String) {
        send([
            "type":   sdp.type == .offer ? "offer" : "answer",
            "sdp":    sdp.sdp,
            "peerId": peerId
        ])
    }

    func sendCandidate(_ candidate: RTCIceCandidate, to peerId: String) {
        var p: [String: Any] = [
            "type":           "candidate",
            "sdp":            candidate.sdp,
            "sdpMLineIndex":  candidate.sdpMLineIndex,
            "peerId":         peerId
        ]
        if let mid = candidate.sdpMid { p["sdpMid"] = mid }
        send(p)
    }

    func sendHangup() { send(["type": "hangup"]) }

    private func send(_ payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A) // newline
        Task {
            do { try await ipc.write(data: data) }
            catch { print("[BareKitBridge] write error: \(error)") }
        }
    }
}
