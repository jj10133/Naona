//
//  RootView.swift
//  App
//
//  Created by Janardhan on 2026-03-22.
//

import SwiftUI

// MARK: - RootView

struct RootView: View {
    @ObservedObject var router: AppRouter
    let worker: Worker

    var body: some View {
        Group {
            if let vm = router.activeCall {
                VideoCallView(vm: vm)
                    .transition(.opacity)
            } else {
                LobbyView { topic, mode in
                    router.startCall(ipc: worker.ipc, topic: topic, mode: mode)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: router.activeCall == nil)
        .preferredColorScheme(.dark)
    }
}
