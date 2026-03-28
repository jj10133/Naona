// Views/VideoCallView.swift

import SwiftUI

// MARK: - VideoSurfaceView (platform wrapper)

#if os(iOS)
import UIKit
struct VideoSurfaceView: UIViewRepresentable {
    let surface: VideoSurface
    func makeUIView(context: Context) -> VideoSurface { surface }
    func updateUIView(_ uiView: VideoSurface, context: Context) {}
    static func dismantleUIView(_ uiView: VideoSurface, coordinator: ()) {}
}
#elseif os(macOS)
import AppKit
struct VideoSurfaceView: NSViewRepresentable {
    let surface: VideoSurface
    func makeNSView(context: Context) -> VideoSurface { surface }
    func updateNSView(_ nsView: VideoSurface, context: Context) {}
    static func dismantleNSView(_ nsView: VideoSurface, coordinator: ()) {}
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

            mainVideoArea
                .ignoresSafeArea()

            if controlsVisible || vm.renderers.isEmpty {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.easeInOut(duration: 0.3),  value: vm.renderers.count)
        .onChange(of: vm.callState.isTerminal) { isTerminal in
            if isTerminal { vm.onCallEnded?() }
        }
        .onAppear { scheduleHide() }
    }

    // MARK: - Main video area

    @ViewBuilder
    private var mainVideoArea: some View {
        if vm.renderers.isEmpty {
            waitingView
        } else if vm.renderers.count == 1 {
            oneToOneView(vm.renderers[0])
        } else {
            meshGridView
        }
    }

    // 1-to-1: remote fullscreen + local PiP
    private func oneToOneView(_ renderer: MediaRenderer) -> some View {
        ZStack(alignment: .topTrailing) {
            VideoSurfaceView(surface: renderer.videoSurface)
                .onTapGesture { toggleControls() }

            // Local camera PiP
            if let local = vm.localRenderer {
                VideoSurfaceView(surface: local.videoSurface)
                    .frame(width: 120, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 8)
                    .padding(.top, topPadding + 44)
                    .padding(.trailing, 16)
            }
        }
    }

    // Mesh: responsive grid
    private var meshGridView: some View {
        GeometryReader { geo in
            let count = vm.renderers.count
            let cols  = count <= 2 ? 1 : 2
            let rows  = (count + cols - 1) / cols
            let cellW = geo.size.width  / CGFloat(cols)
            let cellH = geo.size.height / CGFloat(rows)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: cols),
                spacing: 2
            ) {
                ForEach(vm.renderers) { renderer in
                    VideoSurfaceView(surface: renderer.videoSurface)
                        .frame(width: cellW, height: cellH)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .onTapGesture { toggleControls() }
    }

    // Waiting screen — shows local camera while waiting for peer
    private var waitingView: some View {
        ZStack {
            // Local camera feed (full screen while waiting)
            if let local = vm.localRenderer {
                VideoSurfaceView(surface: local.videoSurface)
            } else {
                Color(white: 0.1)
            }
            // Status overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text(vm.callState.label)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                        Text("Waiting for others…")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding()
                }
            }
        }
        .onTapGesture { toggleControls() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            statusPill

            Spacer()

            if vm.mode == .mesh && !vm.renderers.isEmpty {
                peerCountBadge
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
    }

    private var statusPill: some View {
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
    }

    private var peerCountBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.fill").font(.caption2)
            Text("\(vm.renderers.count + 1)").font(.caption.weight(.semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    // MARK: - Bottom controls

    private var bottomBar: some View {
        HStack(spacing: 20) {
            circleButton(
                icon: vm.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                bg:   vm.isAudioMuted ? .red : Color.white.opacity(0.2),
                size: 56
            ) { vm.toggleMute() }

            circleButton(icon: "phone.down.fill", bg: .red, size: 72) {
                vm.hangup()
            }

            circleButton(
                icon: vm.isVideoMuted ? "video.slash.fill" : "video.fill",
                bg:   vm.isVideoMuted ? .red : Color.white.opacity(0.2),
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

    private func circleButton(
        icon: String, bg: Color, size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
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

    // MARK: - Auto-hide controls

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
                if !vm.renderers.isEmpty {
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
