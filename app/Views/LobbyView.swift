// Views/LobbyView.swift
// Room code UX — user types a short human-readable code (e.g. "TIGER-7")
// which is SHA256-hashed to 32 bytes to form the Hyperswarm topic.
// Both peers must type the same code → same topic → they find each other.

import SwiftUI
import CryptoKit

struct LobbyView: View {

    var onStart: (_ topic: String, _ mode: CallMode) -> Void

    @State private var roomCode  = ""
    @State private var mode: CallMode = .one
    @FocusState private var fieldFocused: Bool

    private var isValid: Bool { roomCode.trimmingCharacters(in: .whitespaces).count >= 3 }

    // SHA256 the room code → 64-char hex topic for Hyperswarm
    private var topic: String {
        let input = roomCode.trimmingCharacters(in: .whitespaces).lowercased()
        let hash  = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.08), Color(white: 0.04)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                brandHeader
                Spacer()
                inputCard
                Spacer().frame(height: 48)
            }
        }
    }

    // MARK: - Brand header

    private var brandHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .green.opacity(0.4), radius: 20)

            Text("Naona")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)

            Text("P2P encrypted video")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Input card

    private var inputCard: some View {
        VStack(spacing: 16) {
            modePicker
            roomCodeField
            HStack(spacing: 12) {
                generateButton
                if isValid { copyButton }
            }
            startButton
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 0) {
            modeTab(label: "1-to-1", icon: "person.2.fill", value: .one)
            modeTab(label: "Group",  icon: "person.3.fill", value: .mesh)
        }
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func modeTab(label: String, icon: String, value: CallMode) -> some View {
        let selected = mode == value
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { mode = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(selected ? .black : .white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? Color.green : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Room code field

    private var roomCodeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Room Code")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.5))
                .textCase(.uppercase)
                .tracking(1)

            HStack {
                TextField("e.g. tiger-7 or any word…", text: $roomCode)
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(.white)
                    .focused($fieldFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    #endif

                if !roomCode.isEmpty {
                    Button { roomCode = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isValid ? Color.green.opacity(0.6) : Color.white.opacity(0.1),
                        lineWidth: 1
                    )
            )

            if isValid {
                Text("Topic: \(topic.prefix(16))…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    private var generateButton: some View {
        Button {
            roomCode = _randomCode()
        } label: {
            Label("Generate", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private var copyButton: some View {
        Button {
            #if os(iOS)
            UIPasteboard.general.string = roomCode
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(roomCode, forType: .string)
            #endif
        } label: {
            Label("Copy code", systemImage: "doc.on.doc")
                .font(.caption)
                .foregroundColor(.green.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Start button

    private var startButton: some View {
        Button {
            guard isValid else { return }
            fieldFocused = false
            onStart(topic, mode)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: mode == .one ? "video.fill" : "person.3.fill")
                    .font(.system(size: 17, weight: .semibold))
                Text(mode == .one ? "Start Call" : "Start Group Call")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isValid ? Color.green : Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: isValid ? .green.opacity(0.35) : .clear, radius: 12)
        }
        .buttonStyle(.plain)
        .disabled(!isValid)
        .animation(.easeInOut(duration: 0.2), value: isValid)
    }

    // MARK: - Helpers

    private func _randomCode() -> String {
        let words = ["tiger", "river", "storm", "echo", "frost", "lunar", "swift", "delta", "nova", "prism"]
        let word  = words.randomElement() ?? "hello"
        let num   = Int.random(in: 10...99)
        return "\(word)-\(num)"
    }
}
