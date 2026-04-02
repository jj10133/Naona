// AppRouter.swift

import Foundation
import BareKit
import AVFoundation

@MainActor
final class AppRouter: ObservableObject {
    @Published var activeCall: CallViewModel? = nil

    func startCall(ipc: IPC, topic: String, role: CallRole) {
        requestMediaPermissions {
            let vm = CallViewModel(ipc: ipc)
            vm.onCallEnded = { [weak self] in self?.activeCall = nil }
            vm.startCall(topic: topic, role: role)
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
