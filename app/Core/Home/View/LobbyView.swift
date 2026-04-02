// LobbyView.swift

import SwiftUI
import CryptoKit

struct LobbyView: View {

    var onStart: (_ topic: String, _ role: CallRole) -> Void

    @State private var roomCode = ""
    @State private var screen:  Screen = .home

    private enum Screen { case home, create, join }

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

                switch screen {
                case .home:   homeButtons
                case .create: createCard
                case .join:   joinCard
                }

                Spacer().frame(height: 48)
            }
            .padding(.horizontal, 24)
        }
        .animation(.easeInOut(duration: 0.2), value: screen)
    }

    // MARK: - Brand

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

    // MARK: - Home screen

    private var homeButtons: some View {
        VStack(spacing: 14) {
            // Create Room → host role
            actionButton(
                title:    "Create Room",
                subtitle: "Start a call, share the code",
                icon:     "plus.circle.fill",
                color:    .green
            ) {
                // Generate a fresh room code and go straight to create screen
                roomCode = _generateCode()
                screen   = .create
            }

            // Join Room → guest role
            actionButton(
                title:    "Join Room",
                subtitle: "Enter a code to join",
                icon:     "arrow.right.circle.fill",
                color:    .blue
            ) {
                roomCode = ""
                screen   = .join
            }
        }
    }

    private func actionButton(
        title: String, subtitle: String, icon: String,
        color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(color)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(18)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Create card (host)

    private var createCard: some View {
        VStack(spacing: 20) {
            cardHeader(title: "Your Room Code", subtitle: "Share this code with participants") {
                screen = .home
            }

            // Display the generated code — large and copyable
            VStack(spacing: 8) {
                Text(roomCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                    .background(Color.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

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

            // Start button — host joins as group host
            startButton(title: "Start Room", color: .green) {
                let topic = _topic(from: roomCode)
                onStart(topic, .host)
            }

            // Regenerate
            Button {
                roomCode = _generateCode()
            } label: {
                Label("New code", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    // MARK: - Join card (guest)

    @FocusState private var joinFieldFocused: Bool

    private var joinCard: some View {
        VStack(spacing: 20) {
            cardHeader(title: "Join a Room", subtitle: "Enter the host's room code") {
                screen = .home
            }

            // Code input
            TextField("e.g. nova-42", text: $roomCode)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .focused($joinFieldFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(joinValid ? Color.blue.opacity(0.7) : Color.white.opacity(0.1), lineWidth: 1)
                )

            startButton(title: "Join Room", color: .blue, enabled: joinValid) {
                let topic = _topic(from: roomCode.trimmingCharacters(in: .whitespaces).lowercased())
                onStart(topic, .guest)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private var joinValid: Bool {
        roomCode.trimmingCharacters(in: .whitespaces).count >= 3
    }

    // MARK: - Shared components

    private func cardHeader(title: String, subtitle: String, back: @escaping () -> Void) -> some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
    }

    private func startButton(
        title: String, color: Color, enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(enabled ? color : Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: enabled ? color.opacity(0.4) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.15), value: enabled)
    }

    // MARK: - Helpers

    // SHA256 of the lowercase code → 64 hex chars (32 bytes for Hyperswarm)
    private func _topic(from code: String) -> String {
        let hash = SHA256.hash(data: Data(code.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func _generateCode() -> String {
        let words = ["nova", "tiger", "frost", "echo", "lunar", "swift", "delta", "prism", "storm", "river"]
        let num   = Int.random(in: 10...99)
        return "\(words.randomElement() ?? "nova")-\(num)"
    }
}
