import SwiftUI

struct VoiceOrb: View {
    let state: AppModel.VoiceState
    var accent: Color
    @State private var time = Date().timeIntervalSinceReferenceDate

    /// Main internal glow colour.
    private var tint: Color {
        switch state {
        case .idle: return Color(white: 0.55)
        case .listening: return accent
        case .thinking: return .purple
        case .speaking: return .green
        }
    }

    /// Secondary glow colour, drifting against the main one for a living, fluid look.
    private var tint2: Color {
        switch state {
        case .idle: return Color(white: 0.35)
        case .listening: return accent.opacity(0.85)
        case .thinking: return .blue
        case .speaking: return .mint
        }
    }

    /// Third accent colour for a richer, more iridescent mix inside the glass.
    private var tint3: Color {
        switch state {
        case .idle: return Color(white: 0.7)
        case .listening: return .cyan
        case .thinking: return .pink
        case .speaking: return .teal
        }
    }

    /// How quickly the internal energy drifts (radians/sec).
    private var innerSpeed: Double {
        switch state {
        case .idle: return 0.12
        case .listening: return 0.45
        case .thinking: return 0.6
        case .speaking: return 0.5
        }
    }

    var body: some View {
        content(t: time)
            .frame(width: 260, height: 260)
            .animation(.easeInOut(duration: 0.5), value: state)
            .onReceive(Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()) { date in
                time = date.timeIntervalSinceReferenceDate
            }
    }

    @ViewBuilder
    private func content(t: TimeInterval) -> some View {
        let size: CGFloat = 200
        let m = t * innerSpeed
        let breathe = 1 + 0.018 * sin(t * 1.1)

        ZStack {
            Ellipse()
                .fill(.black.opacity(0.5))
                .frame(width: size * 0.68, height: size * 0.13)
                .blur(radius: 18)
                .offset(y: size * 0.62)

            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: size * 1.2, height: size * 1.2)
                .blur(radius: 48)

            ZStack {
                Circle().fill(.ultraThinMaterial)

                Circle().fill(
                    RadialGradient(
                        colors: [tint.opacity(0.55), tint.opacity(0.14), .black.opacity(0.38)],
                        center: .init(x: 0.5, y: 0.42),
                        startRadius: 2, endRadius: size * 0.62
                    )
                )

                ZStack {
                    blob(tint, d: 120, x: cos(m) * 34, y: sin(m * 0.8) * 30)
                    blob(tint2, d: 104, x: cos(m * 1.3 + 2) * 40, y: sin(m + 1) * 34)
                    blob(tint3, d: 92, x: cos(m * 0.9 + 5) * 38, y: sin(m * 1.2 + 2) * 32)
                    blob(tint3, d: 58, x: cos(m * 0.7 + 4) * 24, y: sin(m * 1.1 + 3) * 24, opacity: 0.45)
                }
                .blur(radius: 24)

                Circle().fill(
                    RadialGradient(
                        colors: [tint.opacity(0.5), .clear],
                        center: .init(x: 0.5, y: 0.82),
                        startRadius: 0, endRadius: size * 0.4
                    )
                )
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(
                    AngularGradient(
                        colors: [tint3.opacity(0.7), .clear, tint.opacity(0.5), .clear,
                                 tint2.opacity(0.6), .clear, tint3.opacity(0.7)],
                        center: .center, angle: .degrees(-45)
                    ),
                    lineWidth: 1.5
                )
            }
            .scaleEffect(breathe)
            .shadow(color: tint.opacity(0.5), radius: 28)
        }
    }

    private func blob(_ color: Color, d: CGFloat, x: Double, y: Double, opacity: Double = 0.55) -> some View {
        Circle().fill(color.opacity(opacity))
            .frame(width: d, height: d)
            .offset(x: x, y: y)
    }
}

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = statePresentation
        ZStack {
            KonishiPalette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(spacing: 12) {
                    Label(state.title, systemImage: state.symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(state.tint)

                    VoiceOrb(state: model.voiceState, accent: model.currentAccent)
                        .frame(height: 260)
                }

                if let error = model.voice.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: 480)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 12)
                }

                Spacer(minLength: 24)

                Button {
                    model.stopConversation()
                    dismiss()
                } label: {
                    Label("End conversation", systemImage: "phone.down.fill")
                        .frame(minWidth: 190)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .keyboardShortcut(.cancelAction)
                .padding(.bottom, 28)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { model.startConversation() }
        .onDisappear { model.stopConversation() }
        // The model can hang up itself via the end_conversation tool; close the sheet when it does.
        .onChange(of: model.conversationActive) { _, active in
            if !active { dismiss() }
        }
    }

    private var statePresentation: (title: String, symbol: String, tint: Color) {
        switch model.voiceState {
        case .idle: ("Ready", "waveform", .secondary)
        case .listening: ("Listening", "waveform", model.currentAccent)
        case .thinking: ("Thinking", "ellipsis", .orange)
        case .speaking: ("Speaking", "speaker.wave.2", .green)
        }
    }
}
