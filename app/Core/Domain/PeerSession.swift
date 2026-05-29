import SwiftUI
import AVFoundation

@MainActor
final class PeerSession: ObservableObject, Identifiable {
    let id:       String
    let renderer: MediaRenderer

    @Published var isAudioMuted = false
    @Published var isVideoMuted = false

    init(peerId: String) {
        self.id       = peerId
        self.renderer = MediaRenderer(peerId: peerId)
    }

    func stop() { renderer.stop() }
}
