import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var receiver: ReceiverController
    @State private var diagnosticsVisible = false

    var body: some View {
        ZStack {
            waitingBackground

            PixelBufferSurface(frameStore: receiver.frameStore)
                .ignoresSafeArea()
                .opacity(receiver.isStreaming ? 1 : 0)

            if receiver.isStreaming {
                if diagnosticsVisible {
                    diagnosticsOverlay
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                waitingView
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: receiver.isStreaming)
        .animation(.easeInOut(duration: 0.2), value: diagnosticsVisible)
        .onPlayPauseCommand {
            guard receiver.isStreaming else { return }
            diagnosticsVisible.toggle()
        }
        .onChange(of: receiver.isStreaming) { _, isStreaming in
            if !isStreaming {
                diagnosticsVisible = false
            }
            UIApplication.shared.isIdleTimerDisabled = isStreaming
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = receiver.isStreaming
            receiver.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var waitingBackground: some View {
        ZStack {
            Color(red: 0.008, green: 0.014, blue: 0.045)
            RadialGradient(
                colors: [
                    Color(red: 0.055, green: 0.16, blue: 0.38).opacity(0.72),
                    Color.clear
                ],
                center: .center,
                startRadius: 60,
                endRadius: 820
            )
            LinearGradient(
                colors: [Color.cyan.opacity(0.08), .clear, Color.purple.opacity(0.1)],
                startPoint: .bottomLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var waitingView: some View {
        VStack(spacing: 20) {
            Text("QUESTCAST")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .tracking(7)
                .foregroundStyle(.white.opacity(0.7))

            Image("HeadsetHero")
                .resizable()
                .scaledToFit()
                .frame(width: 620, height: 410)
                .shadow(color: .cyan.opacity(0.12), radius: 34, x: -18)
                .shadow(color: .purple.opacity(0.16), radius: 36, x: 18)
                .accessibilityHidden(true)

            VStack(spacing: 13) {
                Text("Waiting for your headset")
                    .font(.system(size: 54, weight: .semibold, design: .rounded))

                Text("Open QuestCast on your headset, then select QuestCast TV.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.68))
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(statusColour)
                    .frame(width: 10, height: 10)
                Text(receiver.status)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.58))
            }
            .padding(.top, 9)

            Label("During casting, press Play/Pause to show stream information", systemImage: "playpause.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.42))
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(60)
    }

    private var diagnosticsOverlay: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 11, height: 11)
                            .shadow(color: .green.opacity(0.8), radius: 7)
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .tracking(2)
                        Spacer()
                        Text("Play/Pause to hide")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("QuestCast")
                        .font(.title2.weight(.semibold))

                    Divider()

                    diagnosticRow("Codec", "H.264 / hardware decode")
                    diagnosticRow("Target", "1920 × 1080  •  60 fps")
                    diagnosticRow("Transport", "UDP / local network")
                    diagnosticRow("Frames received", receiver.framesDecoded.formatted())
                    diagnosticRow("Incomplete frames", receiver.framesDropped.formatted())
                }
                .padding(26)
                .frame(width: 470)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }

                Spacer()
            }
            Spacer()
        }
        .padding(46)
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)
            Text(value)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    private var statusColour: Color {
        receiver.status.hasPrefix("Ready") ? .green : .yellow
    }
}
