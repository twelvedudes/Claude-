import SwiftUI

struct TimerView: View {
    @EnvironmentObject var timerVM: TimerViewModel
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var soundManager: SoundManager
    @EnvironmentObject var themeManager: ThemeManager

    @State private var showCategoryPicker = false
    @State private var showAmbientSounds = false

    var body: some View {
        ZStack {
            // Background
            themeManager.backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                topBar
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                Spacer()

                // Timer ring
                TimerRingView(
                    progress: timerVM.progress,
                    timeString: timerVM.timeString,
                    sessionLabel: timerVM.sessionLabel,
                    sessionType: timerVM.currentSessionType,
                    isRunning: timerVM.timerState == .running
                )
                .padding(.bottom, 20)

                // Session indicators
                sessionIndicators
                    .padding(.bottom, 32)

                Spacer()

                // Controls
                controlButtons
                    .padding(.bottom, 16)

                // Bottom info
                bottomInfo
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showCategoryPicker) {
            categoryPickerSheet
        }
        .sheet(isPresented: $showAmbientSounds) {
            ambientSoundsSheet
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Category selector
            Button {
                showCategoryPicker = true
                HapticManager.shared.light()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: timerVM.selectedCategory.icon)
                        .font(.system(size: 14))
                    Text(timerVM.selectedCategory.rawValue)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .foregroundStyle(themeManager.textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(themeManager.cardColor.opacity(0.6))
                .clipShape(Capsule())
            }

            Spacer()

            // Streak badge
            if timerVM.currentStreak > 0 {
                StreakBadge(streak: timerVM.currentStreak)
            }

            // Ambient sound button
            Button {
                showAmbientSounds = true
                HapticManager.shared.light()
            } label: {
                Image(systemName: soundManager.isPlaying ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(themeManager.textColor)
                    .frame(width: 40, height: 40)
                    .background(themeManager.cardColor.opacity(0.6))
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Session Indicators

    private var sessionIndicators: some View {
        HStack(spacing: 8) {
            ForEach(0..<timerVM.configuration.sessionsUntilLongBreak, id: \.self) { index in
                Circle()
                    .fill(
                        index < timerVM.completedSessions % timerVM.configuration.sessionsUntilLongBreak
                            ? themeManager.selectedTheme.accentColor
                            : themeManager.cardColor.opacity(0.4)
                    )
                    .frame(width: 10, height: 10)
                    .scaleEffect(index == timerVM.completedSessions % timerVM.configuration.sessionsUntilLongBreak ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3), value: timerVM.completedSessions)
            }
        }
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        HStack(spacing: 24) {
            // Stop / Reset
            if timerVM.timerState != .idle {
                Button {
                    timerVM.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(themeManager.textColor)
                        .frame(width: 56, height: 56)
                        .background(themeManager.cardColor.opacity(0.6))
                        .clipShape(Circle())
                }
                .transition(.scale.combined(with: .opacity))
            }

            // Play / Pause
            Button {
                if timerVM.timerState == .running {
                    timerVM.pause()
                } else {
                    timerVM.start()
                }
            } label: {
                Image(systemName: timerVM.timerState == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(themeManager.selectedTheme.backgroundColor)
                    .frame(width: 72, height: 72)
                    .background(themeManager.primaryGradient)
                    .clipShape(Circle())
                    .shadow(color: themeManager.selectedTheme.accentColor.opacity(0.4), radius: 12, y: 4)
            }

            // Skip
            if timerVM.timerState != .idle {
                Button {
                    timerVM.skip()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(themeManager.textColor)
                        .frame(width: 56, height: 56)
                        .background(themeManager.cardColor.opacity(0.6))
                        .clipShape(Circle())
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4), value: timerVM.timerState)
    }

    // MARK: - Bottom Info

    private var bottomInfo: some View {
        HStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("\(timerVM.todaysSessions)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(themeManager.textColor)
                Text("Sessions")
                    .font(.caption2)
                    .foregroundStyle(themeManager.secondaryTextColor)
            }

            // Daily goal progress ring
            ZStack {
                Circle()
                    .stroke(themeManager.cardColor.opacity(0.4), lineWidth: 4)
                    .frame(width: 44, height: 44)

                Circle()
                    .trim(from: 0, to: timerVM.dailyProgress)
                    .stroke(themeManager.primaryGradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-90))

                Text("\(Int(timerVM.dailyProgress * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(themeManager.textColor)
            }

            VStack(spacing: 4) {
                Text(timerVM.todaysFocusMinutes.hourMinuteFormatted)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(themeManager.textColor)
                Text("Focus Time")
                    .font(.caption2)
                    .foregroundStyle(themeManager.secondaryTextColor)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .background(themeManager.cardColor.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Sheets

    private var categoryPickerSheet: some View {
        NavigationStack {
            List {
                ForEach(FocusCategory.allCases) { category in
                    Button {
                        timerVM.selectedCategory = category
                        showCategoryPicker = false
                        HapticManager.shared.selection()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.icon)
                                .font(.system(size: 18))
                                .foregroundStyle(Color(category.color))
                                .frame(width: 32)

                            Text(category.rawValue)
                                .foregroundStyle(.primary)

                            Spacer()

                            if timerVM.selectedCategory == category {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showCategoryPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var ambientSoundsSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SoundManager.AmbientSound.allCases) { sound in
                        Button {
                            if sound.isPremium && !storeManager.isProUser {
                                storeManager.showPaywall = true
                            } else {
                                soundManager.toggleAmbient(sound)
                                HapticManager.shared.selection()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: sound.icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(.accent)
                                    .frame(width: 32)

                                Text(sound.rawValue)
                                    .foregroundStyle(.primary)

                                Spacer()

                                if sound.isPremium && !storeManager.isProUser {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if soundManager.currentAmbientSound == sound && soundManager.isPlaying {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.accent)
                                        .symbolEffect(.variableColor.iterative)
                                }
                            }
                        }
                    }
                }

                if soundManager.isPlaying {
                    Section("Volume") {
                        HStack {
                            Image(systemName: "speaker.fill")
                                .font(.caption)
                            Slider(value: Binding(
                                get: { Double(soundManager.volume) },
                                set: { soundManager.setVolume(Float($0)) }
                            ), in: 0...1)
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Ambient Sounds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAmbientSounds = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
