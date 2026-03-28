// RPC/RPCTransport.swift
// Raw IPC protocol matching lib/rpc.js exactly.
// Every message: [1B command][4B data-length LE][N bytes data]
// No bare-rpc framing — BareKit IPC preserves write boundaries.

import BareKit
import Foundation

typealias IPCMessageHandler = (_ command: UInt8, _ data: Data) -> Void

final class RPCTransport {

    var onMessage: IPCMessageHandler?

    private let ipc:      IPC
    private var readBuf   = Data()
    private var readTask: Task<Void, Never>?

    init(ipc: IPC) {
        self.ipc = ipc
    }

    func start() {
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in self.ipc {
                    self.feed(chunk)
                }
            } catch {
                print("[RPCTransport] IPC ended: \(error)")
            }
        }
        print("[RPCTransport] started")
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
    }

    // Send: [1B cmd][4B len LE][data]
    func send(command: UInt8, data: Data = Data()) {
        var msg = Data(count: 5 + data.count)
        msg[0] = command
        let len = UInt32(data.count).littleEndian
        withUnsafeBytes(of: len) { msg.replaceSubrange(1..<5, with: $0) }
        if !data.isEmpty { msg.replaceSubrange(5..., with: data) }
        Task {
            do { try await ipc.write(data: msg) }
            catch { print("[RPCTransport] write error: \(error)") }
        }
    }

    // Feed incoming bytes, parse complete messages
    private func feed(_ chunk: Data) {
        readBuf.append(chunk)
        while readBuf.count >= 5 {
            let cmd     = readBuf[0]
            let dataLen = Int(readBuf[1..<5].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            })
            guard readBuf.count >= 5 + dataLen else { break }
            let payload = readBuf.subdata(in: 5..<(5 + dataLen))
            readBuf.removeSubrange(0..<(5 + dataLen))
            onMessage?(cmd, payload)
        }
    }
}
