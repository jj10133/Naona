// VideoCallView.swift

import SwiftUI
import WebRTC

// MARK: - VideoRenderer (iOS)

#if os(iOS)
import UIKit

struct VideoRenderer: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView(frame: .zero)
        v.videoContentMode = .scaleAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.currentTrack?.remove(uiView)
        context.coordinator.currentTrack = track
        track?.add(uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.currentTrack?.remove(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var currentTrack: RTCVideoTrack? }
}

#elseif os(macOS)
import AppKit

struct VideoRenderer: NSViewRepresentable {
    let track: RTCVideoTrack?

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let v = RTCMTLNSVideoView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {
        context.coordinator.currentTrack?.remove(nsView)
        context.coordinator.currentTrack = track
        track?.add(nsView)
    }

    static func dismantleNSView(_ nsView: RTCMTLNSVideoView, coordinator: Coordinator) {
        coordinator.currentTrack?.remove(nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var currentTrack: RTCVideoTrack? }
}
#endif

// MARK: - VideoCallView

struct VideoCallView: View {

    @ObservedObject var vm: CallViewModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Main video area — switches between 1-to-1 and grid
            if vm.peers.isEmpty {
                waitingView
            } else if vm.mode == .one, let peer = vm.peers.first {
                oneToOneLayout(peer: peer)
            } else {
                meshLayout
            }

            // Overlay controls
            if controlsVisible || vm.peers.isEmpty {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.easeInOut(duration: 0.3), value: vm.peers.count)
        .onChange(of: vm.callState.isTerminal) { if $0 { vm.onCallEnded?() } }
        .onAppear { scheduleHide() }
    }

    // MARK: - 1-to-1 layout (FaceTime style)

    private func oneToOneLayout(peer: PeerSession) -> some View {
        ZStack {
            // Remote fullscreen
            VideoRenderer(track: peer.remoteVideoTrack)
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            // Local PiP top-right
            VStack {
                HStack {
                    Spacer()
                    localPiP
                        .padding(.top, topPadding)
                        .padding(.trailing, 16)
                }
                Spacer()
            }
        }
    }

    // MARK: - Mesh grid layout

    private var meshLayout: some View {
        GeometryReader { geo in
            let count = vm.peers.count
            let cols = count <= 2 ? 1 : 2
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cellW = geo.size.width / CGFloat(cols)
            let cellH = geo.size.height / CGFloat(rows)

            ZStack {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: cols),
                    spacing: 2
                ) {
                    ForEach(vm.peers) { peer in
                        ZStack(alignment: .bottomLeading) {
                            VideoRenderer(track: peer.remoteVideoTrack)
                                .frame(width: cellW, height: cellH)
                                .background(Color(white: 0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            // Peer status dot
                            Circle()
                                .fill(peer.connectionState == .connected ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                                .padding(8)
                        }
                    }
                }

                // Local PiP in corner
                VStack {
                    HStack {
                        Spacer()
                        localPiP
                            .padding(.top, topPadding)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .onTapGesture { toggleControls() }
    }

    // MARK: - Waiting screen

    private var waitingView: some View {
        ZStack {
            Color(white: 0.1).ignoresSafeArea()
            VStack(spacing: 20) {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 100, height: 100)
                    .overlay(
                        Image(systemName: vm.mode == .one ? "person.fill" : "person.3.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.6))
                    )

                VStack(spacing: 6) {
                    Text(vm.callState.label)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.white)
                    Text("Waiting for others to join…")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .onTapGesture { toggleControls() }
    }

    // MARK: - Local PiP

    private var localPiP: some View {
        VideoRenderer(track: vm.localVideoTrack)
            .frame(width: 88, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(radius: 10)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            HStack(spacing: 5) {
                Circle()
                    .fill(vm.callState.dotColor)
                    .frame(width: 7, height: 7)
                Text(vm.callState.label)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

            Spacer()

            // Peer count badge for mesh calls
            if vm.mode == .mesh && !vm.peers.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                    Text("\(vm.peers.count + 1)")
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
    }

    // MARK: - Bottom controls

    private var bottomBar: some View {
        HStack(spacing: 20) {
            circleButton(
                icon: vm.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                bg: vm.isAudioMuted ? .red : Color.white.opacity(0.2),
                size: 56
            ) { vm.toggleMute() }

            circleButton(icon: "phone.down.fill", bg: .red, size: 72) {
                vm.hangup()
            }

            circleButton(
                icon: vm.isVideoEnabled ? "video.fill" : "video.slash.fill",
                bg: vm.isVideoEnabled ? Color.white.opacity(0.2) : .red,
                size: 56
            ) { vm.toggleVideo() }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 32)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .padding(.horizontal, 40)
        .padding(.bottom, bottomPadding)
    }

    private func circleButton(icon: String, bg: Color, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(bg)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Auto-hide

    private func toggleControls() {
        withAnimation { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if !vm.peers.isEmpty {
                    withAnimation { controlsVisible = false }
                }
            }
        }
    }

    private var topPadding: CGFloat {
        #if os(iOS)
        return 52
        #else
        return 20
        #endif
    }

    private var bottomPadding: CGFloat {
        #if os(iOS)
        return 40
        #else
        return 24
        #endif
    }
}

