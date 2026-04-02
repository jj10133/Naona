// RootView.swift

import SwiftUI

struct RootView: View {
    @ObservedObject var router: AppRouter
    let worker: Worker

    var body: some View {
        Group {
            if let vm = router.activeCall {
                VideoCallView(vm: vm)
                    .transition(.opacity)
            } else {
                LobbyView { topic, role in
                    router.startCall(ipc: worker.ipc, topic: topic, role: role)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: router.activeCall == nil)
        .preferredColorScheme(.dark)
    }
}
