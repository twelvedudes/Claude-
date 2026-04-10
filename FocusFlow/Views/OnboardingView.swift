import SwiftUI

struct OnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    @State private var currentPage = 0

    private let pages: [(image: String, title: String, subtitle: String)] = [
        ("brain.head.profile", "Deep Focus", "Eliminate distractions and train your brain to focus deeply with proven Pomodoro intervals."),
        ("chart.line.uptrend.xyaxis", "Track Progress", "See your productivity grow with detailed statistics, streaks, and daily goals."),
        ("speaker.wave.3.fill", "Stay in the Zone", "Choose from ambient sounds to create your perfect focus environment."),
        ("sparkles", "Unlock Your Potential", "Go Pro for custom timers, premium themes, and advanced analytics.")
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0a0a1a"), Color(hex: "1a1a3e")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip button
                HStack {
                    Spacer()
                    if currentPage < pages.count - 1 {
                        Button("Skip") {
                            withAnimation {
                                hasSeenOnboarding = true
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .frame(height: 44)

                Spacer()

                // Content
                TabView(selection: $currentPage) {
                    ForEach(pages.indices, id: \.self) { index in
                        VStack(spacing: 32) {
                            Image(systemName: pages[index].image)
                                .font(.system(size: 80, weight: .light))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: gradientColors(for: index),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: gradientColors(for: index)[0].opacity(0.4), radius: 30)
                                .padding(.bottom, 16)

                            VStack(spacing: 12) {
                                Text(pages[index].title)
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)

                                Text(pages[index].subtitle)
                                    .font(.body)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .padding(.horizontal, 40)
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                Spacer()

                // Page indicators
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == currentPage ? Color.white : Color.white.opacity(0.3))
                            .frame(width: index == currentPage ? 24 : 8, height: 8)
                            .animation(.spring(response: 0.3), value: currentPage)
                    }
                }
                .padding(.bottom, 40)

                // Button
                Button {
                    if currentPage < pages.count - 1 {
                        withAnimation(.spring(response: 0.4)) {
                            currentPage += 1
                        }
                    } else {
                        withAnimation {
                            hasSeenOnboarding = true
                        }
                    }
                    HapticManager.shared.medium()
                } label: {
                    Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            LinearGradient(
                                colors: gradientColors(for: currentPage),
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: gradientColors(for: currentPage)[0].opacity(0.4), radius: 16, y: 8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }

    private func gradientColors(for index: Int) -> [Color] {
        switch index {
        case 0: return [Color(hex: "6275fc"), Color(hex: "8b5cf6")]
        case 1: return [.green, .teal]
        case 2: return [.orange, .pink]
        case 3: return [.yellow, .orange]
        default: return [.blue, .purple]
        }
    }
}
