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
            do {
                for try await chunk in self.ipc {
                    self.rpc.receive(chunk)
                }
            } catch {
                print("[RPCTransport] read loop ended: \(error)")
            }
        }
        print("[RPCTransport] started")
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
