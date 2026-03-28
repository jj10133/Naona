// RPC/RPCTransport.swift
// BareKit IPC is an AsyncSequence — iterate with for await to receive chunks.

import BareKit
import BareRPC
import Foundation

final class RPCTransport {

    let rpc: RPC

    private let ipc:         IPC
    private let ipcDelegate: _IPCDelegate
    private var readTask:    Task<Void, Never>?

    init(ipc: IPC) {
        self.ipc         = ipc
        self.ipcDelegate = _IPCDelegate(ipc: ipc)
        self.rpc         = RPC(delegate: ipcDelegate)
    }

    func start() {
        readTask = Task { [weak self] in
            guard let self else { return }
            var count = 0
            do {
                for try await chunk in self.ipc {
                    count += 1
                    if count <= 5 || count % 100 == 0 {
                        print("[RPCTransport] rx chunk #\(count) bytes:\(chunk.count)")
                    }
                    self.rpc.receive(chunk)
                }
                print("[RPCTransport] read loop ended normally after \(count) chunks")
            } catch {
                print("[RPCTransport] read loop error after \(count) chunks: \(error)")
            }
        }
        print("[RPCTransport] started, waiting for IPC data")
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
    }
}

// MARK: - Outbound: RPC → IPC

private final class _IPCDelegate: RPCDelegate {
    private let ipc: IPC

    init(ipc: IPC) { self.ipc = ipc }

    func rpc(_ rpc: RPC, send data: Data) {
        Task {
            do {
                try await self.ipc.write(data: data)
            } catch {
                print("[RPCTransport] IPC write error: \(error)")
            }
        }
    }
}
