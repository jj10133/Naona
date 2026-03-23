// App.swift

import BareKit
import SwiftUI

// MARK: - App

@main
struct App: SwiftUI.App {

    @StateObject private var worker = Worker()
    @StateObject private var router = AppRouter()
    @State private var isStarted = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(router: router, worker: worker)
                .onAppear { worker.start(); isStarted = true }
                .onDisappear { worker.terminate() }
        }
        .onChange(of: scenePhase) { phase in
            guard isStarted else { return }
            switch phase {
            case .background: worker.suspend()
            case .active:     worker.resume()
            default: break
            }
        }
    }
}
