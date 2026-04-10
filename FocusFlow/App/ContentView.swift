import SwiftUI

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var storeManager: StoreManager
    @State private var selectedTab: Tab = .timer

    enum Tab: String, CaseIterable {
        case timer = "Timer"
        case stats = "Stats"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .timer: return "timer"
            case .stats: return "chart.bar.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content
            Group {
                switch selectedTab {
                case .timer:
                    TimerView()
                case .stats:
                    StatsView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Custom tab bar
            customTabBar
        }
        .ignoresSafeArea(.keyboard)
        .fullScreenCover(isPresented: $storeManager.showPaywall) {
            PaywallView()
        }
    }

    // MARK: - Custom Tab Bar

    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { tab in
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        selectedTab = tab
                    }
                    HapticManager.shared.selection()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(
                                selectedTab == tab
                                    ? themeManager.selectedTheme.accentColor
                                    : themeManager.secondaryTextColor
                            )
                            .scaleEffect(selectedTab == tab ? 1.1 : 1.0)

                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(
                                selectedTab == tab
                                    ? themeManager.selectedTheme.accentColor
                                    : themeManager.secondaryTextColor
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .fill(themeManager.backgroundColor.opacity(0.8))
                )
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
