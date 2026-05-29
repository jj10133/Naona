import SwiftUI
import AVFoundation

// MARK: - Platform video views

#if os(iOS)
import UIKit

final class VideoHostView: UIView {
    private var displayLayer: AVSampleBufferDisplayLayer?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer?.removeFromSuperlayer()
        displayLayer = layer
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.addSublayer(layer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}

struct VideoView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> VideoHostView {
        let v = VideoHostView(); v.backgroundColor = .black; v.attach(layer); return v
    }
    func updateUIView(_ v: VideoHostView, context: Context) { v.attach(layer) }
}

final class PreviewHostView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    func attach(_ l: AVCaptureVideoPreviewLayer?) {
        previewLayer?.removeFromSuperlayer(); previewLayer = l
        guard let l else { return }
        l.videoGravity = .resizeAspectFill; l.frame = bounds; layer.addSublayer(l)
    }
    override func layoutSubviews() { super.layoutSubviews(); previewLayer?.frame = bounds }
}

struct PreviewView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer?
    func makeUIView(context: Context) -> PreviewHostView {
        let v = PreviewHostView(); v.backgroundColor = .black; v.attach(layer); return v
    }
    func updateUIView(_ v: PreviewHostView, context: Context) { v.attach(layer) }
}

#elseif os(macOS)
import AppKit

final class VideoHostView: NSView {
    private var displayLayer: AVSampleBufferDisplayLayer?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer?.removeFromSuperlayer()
        displayLayer = layer
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        layer.videoGravity = .resizeAspectFill
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
        self.layer?.addSublayer(layer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }
}

struct VideoView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> VideoHostView {
        let v = VideoHostView(); v.attach(layer); return v
    }
    func updateNSView(_ v: VideoHostView, context: Context) {
        v.attach(layer)
    }
}

final class PreviewHostView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    func attach(_ l: AVCaptureVideoPreviewLayer?) {
        previewLayer?.removeFromSuperlayer(); previewLayer = l
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        guard let l else { return }
        l.videoGravity = .resizeAspectFill
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.frame = bounds
        CATransaction.commit()
        self.layer?.addSublayer(l)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = bounds
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }
}

struct PreviewView: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer?

    func makeNSView(context: Context) -> PreviewHostView {
        let v = PreviewHostView(); v.attach(layer); return v
    }
    func updateNSView(_ v: PreviewHostView, context: Context) {
        v.attach(layer)
    }
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

            if vm.peers.isEmpty {
                waitingView
            } else if vm.peers.count == 1 {
                oneToOneLayout(vm.peers[0])
            } else {
                gridLayout
            }

            if controlsVisible || vm.peers.isEmpty {
                VStack { topBar; Spacer(); bottomBar }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.easeInOut(duration: 0.3),  value: vm.peers.count)
        .onChange(of: vm.callState.isTerminal) { if $0 { vm.onCallEnded?() } }
        .onAppear { scheduleHide() }
    }

    // MARK: - Layouts

    private func oneToOneLayout(_ peer: PeerSession) -> some View {
        ZStack(alignment: .topTrailing) {
            VideoView(layer: peer.renderer.makeVideoLayer())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            PreviewView(layer: vm.previewLayer)
                .frame(width: 88, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(radius: 10)
                .padding(.top, topPadding)
                .padding(.trailing, 16)
        }
    }

    private var gridLayout: some View {
        GeometryReader { geo in
            let cols  = vm.peers.count <= 2 ? 1 : 2
            let rows  = Int(ceil(Double(vm.peers.count) / Double(cols)))
            let cellW = geo.size.width  / CGFloat(cols)
            let cellH = geo.size.height / CGFloat(rows)

            ZStack {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: cols),
                    spacing: 2
                ) {
                    ForEach(vm.peers) { peer in
                        ZStack(alignment: .bottomLeading) {
                            if peer.isVideoMuted {
                                ZStack {
                                    Color(white: 0.12)
                                    Image(systemName: "video.slash.fill")
                                        .font(.system(size: 32))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            } else {
                                VideoView(layer: peer.renderer.makeVideoLayer())
                            }
                            HStack(spacing: 4) {
                                if peer.isAudioMuted { muteIcon("mic.slash.fill") }
                                if peer.isVideoMuted { muteIcon("video.slash.fill") }
                            }
                            .padding(6)
                        }
                        .frame(width: cellW, height: cellH)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                VStack {
                    HStack {
                        Spacer()
                        PreviewView(layer: vm.previewLayer)
                            .frame(width: 88, height: 132)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.25), lineWidth: 1))
                            .shadow(radius: 10)
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

    // MARK: - Waiting

    private var waitingView: some View {
        ZStack {
            Color(white: 0.1).ignoresSafeArea()
            VStack(spacing: 20) {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 100, height: 100)
                    .overlay(
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 38))
                            .foregroundColor(.white.opacity(0.6))
                    )
                VStack(spacing: 6) {
                    Text(vm.callState.label)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.white)
                    Text(vm.role == .host ? "Waiting for guests…" : "Connecting to room…")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                    if vm.participantCount > 1 {
                        Text("\(vm.participantCount) in room")
                            .font(.caption)
                            .foregroundColor(.green.opacity(0.8))
                    }
                }
            }
        }
        .onTapGesture { toggleControls() }
    }

    // MARK: - Controls

    private func muteIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(5)
            .background(Color.red.opacity(0.85))
            .clipShape(Circle())
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(vm.callState.dotColor).frame(width: 7, height: 7)
                Text(vm.callState.label).font(.caption.weight(.medium)).foregroundColor(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial).clipShape(Capsule())

            Spacer()

            if vm.participantCount > 1 {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill").font(.caption2)
                    Text("\(vm.participantCount)").font(.caption.weight(.semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial).clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.top, topPadding)
    }

    private var bottomBar: some View {
        HStack(spacing: 20) {
            circleButton(icon: vm.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                         bg: vm.isAudioMuted ? .red : Color.white.opacity(0.2), size: 56) { vm.toggleMute() }
            circleButton(icon: "phone.down.fill", bg: .red, size: 72) { vm.hangup() }
            circleButton(icon: vm.isVideoEnabled ? "video.fill" : "video.slash.fill",
                         bg: vm.isVideoEnabled ? Color.white.opacity(0.2) : .red, size: 56) { vm.toggleVideo() }
        }
        .padding(.vertical, 20).padding(.horizontal, 32)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .padding(.horizontal, 40).padding(.bottom, bottomPadding)
    }

    private func circleButton(icon: String, bg: Color, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(.white).frame(width: size, height: size)
                .background(bg).clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

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
                if !vm.peers.isEmpty { withAnimation { controlsVisible = false } }
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
