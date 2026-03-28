// App.swift

import BareKit
import SwiftUI
import AVFoundation

// MARK: - Worker
// Single responsibility: owns the BareKit Worklet and exposes the IPC handle.

final class Worker: ObservableObject {
    private let worklet = Worklet()
    lazy var ipc: IPC = IPC(worklet: worklet)

    func start()     { worklet.start(name: "app", ofType: "bundle") }
    func terminate() { worklet.terminate() }
    func suspend()   { worklet.suspend() }
    func resume()    { worklet.resume() }
}

// MARK: - AppRouter
// Single responsibility: owns the active call and creates CallViewModel instances.

@MainActor
final class AppRouter: ObservableObject {
    @Published var activeCall: CallViewModel?

    func startCall(ipc: IPC, topic: String, mode: CallMode) {
        let vm = CallViewModel(ipc: ipc)
        vm.onCallEnded = { [weak self] in self?.activeCall = nil }
        vm.startCall(topic: topic, mode: mode)
        activeCall = vm
    }
}

// MARK: - App entry

@main
struct App: SwiftUI.App {

    @StateObject private var worker = Worker()
    @StateObject private var router = AppRouter()
    @State private var isStarted = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(router: router, worker: worker)
                .onAppear {
                    worker.start()
                    isStarted = true
                }
                .onDisappear {
                    worker.terminate()
                }
        }
        .onChange(of: scenePhase) { phase in
            guard isStarted else { return }
            switch phase {
            case .background: worker.suspend()
            case .active:     worker.resume()
            default:          break
            }
        }
    }
}

// MARK: - RootView
// Switches between LobbyView and VideoCallView based on router state.

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
