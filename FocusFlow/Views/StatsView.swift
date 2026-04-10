import SwiftUI
import SwiftData

struct StatsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var storeManager: StoreManager
    @StateObject private var viewModel = StatsViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            themeManager.backgroundColor
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    // Period Picker
                    periodPicker
                        .padding(.horizontal, 24)

                    // Summary Cards
                    summaryCards
                        .padding(.horizontal, 24)

                    // Bar Chart
                    chartSection
                        .padding(.horizontal, 24)

                    // Streak Section
                    streakSection
                        .padding(.horizontal, 24)

                    // Category Breakdown (Pro)
                    if storeManager.isProUser {
                        categorySection
                            .padding(.horizontal, 24)
                    } else {
                        proUpsellCard
                            .padding(.horizontal, 24)
                    }

                    Spacer(minLength: 100)
                }
                .padding(.top, 16)
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
        }
        .onChange(of: viewModel.selectedPeriod) {
            viewModel.loadStats()
        }
    }

    // MARK: - Period Picker

    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(StatsViewModel.StatsPeriod.allCases, id: \.rawValue) { period in
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        viewModel.selectedPeriod = period
                    }
                    HapticManager.shared.selection()
                } label: {
                    Text(period.rawValue)
                        .font(.subheadline)
                        .fontWeight(viewModel.selectedPeriod == period ? .semibold : .regular)
                        .foregroundStyle(
                            viewModel.selectedPeriod == period
                                ? themeManager.selectedTheme.backgroundColor
                                : themeManager.secondaryTextColor
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            viewModel.selectedPeriod == period
                                ? themeManager.selectedTheme.accentColor
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(4)
        .background(themeManager.cardColor.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ], spacing: 12) {
            StatCardView(
                title: "Sessions",
                value: "\(viewModel.totalSessions)",
                icon: "checkmark.circle.fill",
                color: .green
            )

            StatCardView(
                title: "Focus Time",
                value: (viewModel.totalMinutes * 60).hourMinuteFormatted,
                icon: "clock.fill",
                color: themeManager.selectedTheme.accentColor
            )

            StatCardView(
                title: "Avg Session",
                value: "\(viewModel.averageSessionLength)m",
                icon: "chart.bar.fill",
                color: .orange
            )

            StatCardView(
                title: "Best Day",
                value: "\(viewModel.bestDayMinutes)m",
                subtitle: viewModel.bestDay,
                icon: "star.fill",
                color: .yellow
            )
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activity")
                .font(.headline)
                .foregroundStyle(themeManager.textColor)

            if viewModel.dailyData.isEmpty {
                Text("No data yet. Start a focus session!")
                    .font(.subheadline)
                    .foregroundStyle(themeManager.secondaryTextColor)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
            } else {
                chartBars
            }
        }
        .padding(20)
        .background(themeManager.cardColor.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var chartBars: some View {
        let maxMinutes = viewModel.dailyData.map(\.minutes).max() ?? 1

        return VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(viewModel.dailyData) { point in
                    VStack(spacing: 4) {
                        let height = maxMinutes > 0
                            ? CGFloat(point.minutes) / CGFloat(maxMinutes) * 120
                            : CGFloat(0)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(themeManager.primaryGradient)
                            .frame(height: max(4, height))

                        Text(point.label)
                            .font(.system(size: 9))
                            .foregroundStyle(themeManager.secondaryTextColor)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140)
        }
    }

    // MARK: - Streak

    private var streakSection: some View {
        HStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)

                Text("\(viewModel.currentStreak)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(themeManager.textColor)

                Text("Current\nStreak")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(themeManager.secondaryTextColor)
            }
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 60)
                .overlay(themeManager.cardColor)

            VStack(spacing: 8) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.yellow)

                Text("\(viewModel.longestStreak)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(themeManager.textColor)

                Text("Longest\nStreak")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(themeManager.secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background(themeManager.cardColor.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Category

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Categories")
                .font(.headline)
                .foregroundStyle(themeManager.textColor)

            ForEach(viewModel.categoryBreakdown) { stat in
                HStack(spacing: 12) {
                    Image(systemName: stat.category.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(Color(stat.category.color))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.category.rawValue)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(themeManager.textColor)

                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(stat.category.color).opacity(0.3))
                                .frame(width: geo.size.width)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(stat.category.color))
                                        .frame(width: geo.size.width * stat.percentage)
                                }
                        }
                        .frame(height: 6)
                    }

                    Text("\(stat.minutes)m")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(themeManager.secondaryTextColor)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(20)
        .background(themeManager.cardColor.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Pro Upsell

    private var proUpsellCard: some View {
        Button {
            storeManager.showPaywall = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(themeManager.primaryGradient)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock Detailed Analytics")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(themeManager.textColor)

                    Text("See category breakdowns, export data, and more with Pro")
                        .font(.caption)
                        .foregroundStyle(themeManager.secondaryTextColor)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(themeManager.secondaryTextColor)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(themeManager.cardColor.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(themeManager.selectedTheme.accentColor.opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }
}
