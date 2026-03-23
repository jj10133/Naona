//
//  AppRouter.swift
//  App
//
//  Created by Janardhan on 2026-03-22.
//

import Foundation
import BareKit
import AVFoundation

// MARK: - AppRouter

@MainActor
final class AppRouter: ObservableObject {
    @Published var activeCall: CallViewModel? = nil

    func startCall(ipc: IPC, topic: String, mode: CallMode) {
        requestMediaPermissions {
            let vm = CallViewModel(ipc: ipc)
            vm.onCallEnded = { [weak self] in self?.activeCall = nil }
            vm.startCall(topic: topic, mode: mode)
            self.activeCall = vm
        }
    }

    private func requestMediaPermissions(completion: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { completion() }
            }
        }
    }
}
