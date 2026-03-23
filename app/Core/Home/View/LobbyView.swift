//
//  LobbyView.swift
//  App
//
//  Created by Janardhan on 2026-03-22.
//


import SwiftUI

struct LobbyView: View {

    var onStart: (_ topic: String, _ mode: CallMode) -> Void

    @State private var topic = ""
    @State private var mode: CallMode = .one
    @FocusState private var fieldFocused: Bool

    private var isValid: Bool { topic.count == 64 && topic.allSatisfy(\.isHexDigit) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.08), Color(white: 0.04)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // App icon
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

                Spacer()

                VStack(spacing: 16) {

                    // Mode picker
                    HStack(spacing: 0) {
                        modeTab(label: "1-to-1", icon: "person.2.fill", value: .one)
                        modeTab(label: "Group", icon: "person.3.fill", value: .mesh)
                    }
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // Topic field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Join Code")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.5))
                            .textCase(.uppercase)
                            .tracking(1)

                        HStack {
                            TextField("Paste 64-char hex key…", text: $topic)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(.white)
                                .focused($fieldFocused)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.asciiCapable)
                                #endif

                            if !topic.isEmpty {
                                Button { topic = "" } label: {
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
                                .stroke(isValid ? Color.green.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }

                    Button {
                        topic = randomTopic()
                    } label: {
                        Label("Generate new code", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)

                    // Call button
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
                        .background(callButtonBg)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: isValid ? .green.opacity(0.35) : .clear, radius: 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValid)
                    .animation(.easeInOut(duration: 0.2), value: isValid)
                }
                .padding(24)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 20)

                Spacer().frame(height: 48)
            }
        }
    }

    @ViewBuilder
    private var callButtonBg: some View {
        if isValid { Color.green } else { Color.white.opacity(0.1) }
    }

    private func modeTab(label: String, icon: String, value: CallMode) -> some View {
        let selected = mode == value
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { mode = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
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

    private func randomTopic() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
