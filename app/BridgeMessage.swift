// BareKitBridge.swift
// Thin Swift layer that serialises/deserialises JSON messages over BareKit IPC.
// All Hyperswarm signaling logic lives in JS — this file is the Swift ↔ JS boundary.
//
// Message protocol (both directions):
//   { "type": "offer",     "sdp":  "<sdp string>" }
//   { "type": "answer",    "sdp":  "<sdp string>" }
//   { "type": "candidate", "sdp":  "...", "sdpMid": "0", "sdpMLineIndex": 0 }
//   { "type": "call",      "topic": "<32-byte hex discovery topic>" }
//   { "type": "hangup"  }
//   { "type": "ready"   }   // JS → Swift: Hyperswarm peer found, stream open
//   { "type": "error",  "message": "..." }

import BareKit
import WebRTC
import Foundation

// MARK: - Incoming message shapes

enum BridgeMessage {
    case offer(sdp: String)
    case answer(sdp: String)
    case candidate(sdp: String, sdpMid: String?, sdpMLineIndex: Int32)
    case ready
    case hangup
    case error(message: String)
}

// MARK: - Delegate

protocol BareKitBridgeDelegate: AnyObject {
    func bridge(_ bridge: BareKitBridge, didReceive message: BridgeMessage)
}

// MARK: - BareKitBridge

final class BareKitBridge {

    weak var delegate: BareKitBridgeDelegate?

    private let worklet: Worklet

    init(worklet: Worklet) {
        self.worklet = worklet
        // Subscribe to IPC messages coming FROM JS.
        worklet.ipc.onmessage = { [weak self] data in
            self?.handleIncoming(data)
        }
    }

    // MARK: - Swift → JS (outgoing)

    /// Tell JS to start Hyperswarm and join a topic as the caller.
    func sendCall(topic: String) {
        send(["type": "call", "topic": topic])
    }

    /// Send local SDP (offer or answer) to JS for forwarding to the remote peer.
    func sendSDP(_ sdp: RTCSessionDescription) {
        let typeStr = sdp.type == .offer ? "offer" : "answer"
        send(["type": typeStr, "sdp": sdp.sdp])
    }

    /// Send a local ICE candidate to JS for forwarding to the remote peer.
    func sendCandidate(_ candidate: RTCIceCandidate) {
        var payload: [String: Any] = [
            "type": "candidate",
            "sdp": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex
        ]
        if let mid = candidate.sdpMid { payload["sdpMid"] = mid }
        send(payload)
    }

    /// Tell JS to close the Hyperswarm connection and clean up.
    func sendHangup() {
        send(["type": "hangup"])
    }

    // MARK: - JS → Swift (incoming)

    private func handleIncoming(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            print("BareKitBridge: malformed message")
            return
        }

        let msg: BridgeMessage
        switch type {
        case "offer":
            guard let sdp = json["sdp"] as? String else { return }
            msg = .offer(sdp: sdp)

        case "answer":
            guard let sdp = json["sdp"] as? String else { return }
            msg = .answer(sdp: sdp)

        case "candidate":
            guard let sdp = json["sdp"] as? String else { return }
            let mid = json["sdpMid"] as? String
            let idx = (json["sdpMLineIndex"] as? Int).map(Int32.init) ?? 0
            msg = .candidate(sdp: sdp, sdpMid: mid, sdpMLineIndex: idx)

        case "ready":
            msg = .ready

        case "hangup":
            msg = .hangup

        case "error":
            let message = json["message"] as? String ?? "Unknown JS error"
            msg = .error(message: message)

        default:
            print("BareKitBridge: unknown message type '\(type)'")
            return
        }

        DispatchQueue.main.async {
            self.delegate?.bridge(self, didReceive: msg)
        }
    }

    // MARK: - Helpers

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        worklet.ipc.postMessage(data)
    }
}