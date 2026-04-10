import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var timerVM: TimerViewModel
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var themeManager: ThemeManager

    @AppStorage("dailyReminderEnabled") private var dailyReminderEnabled = false
    @AppStorage("dailyReminderHour") private var dailyReminderHour = 9
    @AppStorage("dailyReminderMinute") private var dailyReminderMinute = 0
    @AppStorage("hapticFeedbackEnabled") private var hapticFeedbackEnabled = true

    var body: some View {
        ZStack {
            themeManager.backgroundColor
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    // Pro Badge
                    if storeManager.isProUser {
                        proBadge
                    } else {
                        upgradeCard
                    }

                    // Timer Settings
                    timerSettings

                    // Daily Goal
                    dailyGoalSettings

                    // Themes
                    themeSettings

                    // Notifications
                    notificationSettings

                    // General
                    generalSettings

                    // About
                    aboutSection

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
        }
    }

    // MARK: - Pro Badge

    private var proBadge: some View {
        HStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 24))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("FocusFlow Pro")
                    .font(.headline)
                    .foregroundStyle(themeManager.textColor)
                Text("All features unlocked")
                    .font(.caption)
                    .foregroundStyle(themeManager.secondaryTextColor)
            }

            Spacer()
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.yellow.opacity(0.15), Color.orange.opacity(0.1)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var upgradeCard: some View {
        Button {
            storeManager.showPaywall = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(themeManager.selectedTheme.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Upgrade to Pro")
                        .font(.headline)
                        .foregroundStyle(themeManager.textColor)
                    Text("Unlock custom timers, themes, sounds & more")
                        .font(.caption)
                        .foregroundStyle(themeManager.secondaryTextColor)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(themeManager.secondaryTextColor)
            }
            .padding(20)
            .background(themeManager.cardColor.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(themeManager.selectedTheme.accentColor.opacity(0.3), lineWidth: 1)
            )
        }
    }

    // MARK: - Timer Settings

    private var timerSettings: some View {
        settingsSection(title: "Timer", icon: "timer") {
            if storeManager.isProUser {
                StepperRow(title: "Focus", value: $timerVM.configuration.focusMinutes, range: 5...120, unit: "min")
                StepperRow(title: "Short Break", value: $timerVM.configuration.shortBreakMinutes, range: 1...30, unit: "min")
                StepperRow(title: "Long Break", value: $timerVM.configuration.longBreakMinutes, range: 5...60, unit: "min")
                StepperRow(title: "Sessions to Long Break", value: $timerVM.configuration.sessionsUntilLongBreak, range: 2...8, unit: "")

                Divider().overlay(themeManager.cardColor)

                Toggle("Auto-start Breaks", isOn: $timerVM.configuration.autoStartBreaks)
                    .foregroundStyle(themeManager.textColor)
                Toggle("Auto-start Focus", isOn: $timerVM.configuration.autoStartFocus)
                    .foregroundStyle(themeManager.textColor)
            } else {
                HStack {
                    Text("Focus: 25 min")
                        .foregroundStyle(themeManager.textColor)
                    Spacer()
                    lockBadge
                }
                HStack {
                    Text("Custom intervals require Pro")
                        .font(.caption)
                        .foregroundStyle(themeManager.secondaryTextColor)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Daily Goal

    private var dailyGoalSettings: some View {
        settingsSection(title: "Daily Goal", icon: "target") {
            StepperRow(title: "Target Sessions", value: $timerVM.dailyGoal.targetSessions, range: 1...20, unit: "")
            StepperRow(title: "Target Minutes", value: $timerVM.dailyGoal.targetMinutes, range: 30...600, unit: "min")
        }
    }

    // MARK: - Themes

    private var themeSettings: some View {
        settingsSection(title: "Theme", icon: "paintpalette") {
            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()),
                GridItem(.flexible()), GridItem(.flexible())
            ], spacing: 12) {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        if theme.isPremium && !storeManager.isProUser {
                            storeManager.showPaywall = true
                        } else {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                themeManager.selectedTheme = theme
                            }
                            HapticManager.shared.selection()
                        }
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: theme.previewColors,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 44, height: 44)

                                if themeManager.selectedTheme == theme {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }

                                if theme.isPremium && !storeManager.isProUser {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(.black.opacity(0.5))
                                        .clipShape(Circle())
                                        .offset(x: 14, y: 14)
                                }
                            }

                            Text(theme.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(themeManager.secondaryTextColor)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Notifications

    private var notificationSettings: some View {
        settingsSection(title: "Notifications", icon: "bell") {
            Toggle("Daily Reminder", isOn: $dailyReminderEnabled)
                .foregroundStyle(themeManager.textColor)
                .onChange(of: dailyReminderEnabled) { _, newValue in
                    if newValue {
                        Task {
                            let granted = await NotificationManager.shared.requestAuthorization()
                            if granted {
                                NotificationManager.shared.scheduleDailyReminder(
                                    hour: dailyReminderHour,
                                    minute: dailyReminderMinute
                                )
                            } else {
                                dailyReminderEnabled = false
                            }
                        }
                    } else {
                        NotificationManager.shared.cancelDailyReminder()
                    }
                }

            Toggle("Haptic Feedback", isOn: $hapticFeedbackEnabled)
                .foregroundStyle(themeManager.textColor)
        }
    }

    // MARK: - General

    private var generalSettings: some View {
        settingsSection(title: "General", icon: "gear") {
            if !storeManager.isProUser {
                Button {
                    Task { await storeManager.restorePurchases() }
                } label: {
                    HStack {
                        Text("Restore Purchases")
                            .foregroundStyle(themeManager.textColor)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(themeManager.secondaryTextColor)
                    }
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        settingsSection(title: "About", icon: "info.circle") {
            HStack {
                Text("Version")
                    .foregroundStyle(themeManager.textColor)
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(themeManager.secondaryTextColor)
            }

            HStack {
                Text("Made with")
                    .foregroundStyle(themeManager.textColor)
                Spacer()
                Text("SwiftUI")
                    .foregroundStyle(themeManager.secondaryTextColor)
            }
        }
    }

    // MARK: - Helpers

    private func settingsSection<Content: View>(
        title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(themeManager.selectedTheme.accentColor)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(themeManager.textColor)
            }

            VStack(spacing: 14) {
                content()
            }
        }
        .padding(20)
        .background(themeManager.cardColor.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var lockBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption2)
            Text("PRO")
                .font(.caption2)
                .fontWeight(.bold)
        }
        .foregroundStyle(.yellow)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.yellow.opacity(0.15))
        .clipShape(Capsule())
    }
}

// MARK: - Stepper Row

struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)

            Spacer()

            HStack(spacing: 12) {
                Button {
                    if value > range.lowerBound {
                        value -= (title.contains("Minutes") ? 10 : 1)
                        HapticManager.shared.light()
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .disabled(value <= range.lowerBound)

                Text("\(value)\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(minWidth: 50)

                Button {
                    if value < range.upperBound {
                        value += (title.contains("Minutes") ? 10 : 1)
                        HapticManager.shared.light()
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .disabled(value >= range.upperBound)
            }
        }
    }
}
