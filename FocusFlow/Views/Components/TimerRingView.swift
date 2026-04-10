import SwiftUI

struct TimerRingView: View {
    let progress: Double
    let timeString: String
    let sessionLabel: String
    let sessionType: SessionType
    let isRunning: Bool

    @EnvironmentObject var themeManager: ThemeManager

    private let ringSize: CGFloat = 280
    private let lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            // Background glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            themeManager.selectedTheme.accentColor.opacity(0.15),
                            .clear
                        ],
                        center: .center,
                        startRadius: ringSize * 0.3,
                        endRadius: ringSize * 0.6
                    )
                )
                .frame(width: ringSize + 60, height: ringSize + 60)
                .blur(radius: 20)

            // Track ring
            Circle()
                .stroke(
                    themeManager.cardColor.opacity(0.5),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: ringSize, height: ringSize)

            // Progress ring
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    themeManager.primaryGradient,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: ringSize, height: ringSize)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: progress)

            // Glow dot at progress end
            if progress > 0 {
                Circle()
                    .fill(themeManager.selectedTheme.accentColor)
                    .frame(width: lineWidth + 4, height: lineWidth + 4)
                    .shadow(color: themeManager.selectedTheme.accentColor.opacity(0.6), radius: 8)
                    .offset(y: -ringSize / 2)
                    .rotationEffect(.degrees(360 * progress - 90))
                    .animation(.easeInOut(duration: 0.5), value: progress)
            }

            // Center content
            VStack(spacing: 8) {
                // Session type icon
                Image(systemName: sessionType.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(themeManager.secondaryTextColor)

                // Time display
                Text(timeString)
                    .font(.system(size: 64, weight: .thin, design: .rounded))
                    .foregroundStyle(themeManager.textColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                // Session label
                Text(sessionLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(themeManager.secondaryTextColor)
                    .textCase(.uppercase)
                    .tracking(2)
            }
        }
        .scaleEffect(isRunning ? 1.0 : 0.95)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isRunning)
    }
}

// Animated pulsing ring for idle state
struct PulsingRing: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .stroke(lineWidth: 2)
            .scaleEffect(isPulsing ? 1.1 : 1.0)
            .opacity(isPulsing ? 0 : 0.3)
            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: false), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
