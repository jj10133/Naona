//
//  Worker.swift
//  App
//
//  Created by Janardhan on 2026-03-22.
//

import BareKit
import Foundation

// MARK: - Worker

final class Worker: ObservableObject {
    private let worklet = Worklet()
    lazy var ipc: IPC = IPC(worklet: worklet)

    func start()     { worklet.start(name: "app", ofType: "bundle") }
    func terminate() { worklet.terminate() }
    func suspend()   { worklet.suspend() }
    func resume()    { worklet.resume() }
}
