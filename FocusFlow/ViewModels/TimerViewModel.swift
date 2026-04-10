import SwiftUI
import SwiftData
import Combine

@MainActor
final class TimerViewModel: ObservableObject {
    // MARK: - Timer State
    @Published var timerState: TimerState = .idle
    @Published var currentSessionType: SessionType = .focus
    @Published var remainingSeconds: Int = 25 * 60
    @Published var totalSeconds: Int = 25 * 60
    @Published var completedSessions: Int = 0
    @Published var selectedCategory: FocusCategory = .general

    // MARK: - Configuration
    @Published var configuration: TimerConfiguration {
        didSet {
            saveConfiguration()
            if timerState == .idle {
                resetTimer()
            }
        }
    }

    @Published var dailyGoal: DailyGoal {
        didSet {
            if let data = try? JSONEncoder().encode(dailyGoal) {
                UserDefaults.standard.set(data, forKey: "dailyGoal")
            }
        }
    }

    // MARK: - Stats
    @Published var todaysSessions: Int = 0
    @Published var todaysFocusMinutes: Int = 0
    @Published var currentStreak: Int = 0

    private var timer: Timer?
    private var sessionStartDate: Date?
    private var backgroundDate: Date?
    private var modelContext: ModelContext?

    enum TimerState: Equatable {
        case idle
        case running
        case paused
        case completed
    }

    // MARK: - Computed Properties

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1.0 - (Double(remainingSeconds) / Double(totalSeconds))
    }

    var timeString: String {
        remainingSeconds.timerFormatted
    }

    var sessionLabel: String {
        switch currentSessionType {
        case .focus: return "Focus Time"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }

    var dailyProgress: Double {
        guard dailyGoal.targetSessions > 0 else { return 0 }
        return min(1.0, Double(todaysSessions) / Double(dailyGoal.targetSessions))
    }

    var isOnBreak: Bool {
        currentSessionType != .focus
    }

    // MARK: - Init

    init() {
        if let data = UserDefaults.standard.data(forKey: "timerConfiguration"),
           let config = try? JSONDecoder().decode(TimerConfiguration.self, from: data) {
            self.configuration = config
        } else {
            self.configuration = .free
        }

        if let data = UserDefaults.standard.data(forKey: "dailyGoal"),
           let goal = try? JSONDecoder().decode(DailyGoal.self, from: data) {
            self.dailyGoal = goal
        } else {
            self.dailyGoal = .default
        }

        self.completedSessions = UserDefaults.standard.integer(forKey: "completedSessionsToday")
        resetTimer()
        setupNotifications()
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        loadTodaysStats()
    }

    // MARK: - Timer Controls

    func start() {
        switch timerState {
        case .idle, .completed:
            sessionStartDate = Date()
            timerState = .running
            startTimer()
            scheduleNotification()
            HapticManager.shared.medium()

        case .paused:
            timerState = .running
            startTimer()
            scheduleNotification()
            HapticManager.shared.light()

        case .running:
            break
        }
    }

    func pause() {
        guard timerState == .running else { return }
        timerState = .paused
        stopTimer()
        NotificationManager.shared.cancelTimerNotifications()
        HapticManager.shared.light()
    }

    func stop() {
        let elapsed = totalSeconds - remainingSeconds
        if elapsed > 30 && currentSessionType == .focus {
            saveSession(completed: false, elapsedSeconds: elapsed)
        }
        timerState = .idle
        stopTimer()
        NotificationManager.shared.cancelTimerNotifications()
        resetTimer()
        HapticManager.shared.warning()
    }

    func skip() {
        handleSessionComplete()
        HapticManager.shared.medium()
    }

    // MARK: - Timer Engine

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard remainingSeconds > 0 else { return }

        remainingSeconds -= 1

        if remainingSeconds <= 3 && remainingSeconds > 0 {
            HapticManager.shared.timerTick()
        }

        if remainingSeconds == 0 {
            handleSessionComplete()
        }
    }

    private func handleSessionComplete() {
        stopTimer()
        timerState = .completed
        SoundManager.shared.playTimerEnd()
        HapticManager.shared.sessionComplete()
        SoundManager.shared.stopAmbient()

        if currentSessionType == .focus {
            completedSessions += 1
            todaysSessions += 1
            todaysFocusMinutes += configuration.focusMinutes
            UserDefaults.standard.set(completedSessions, forKey: "completedSessionsToday")
            saveSession(completed: true, elapsedSeconds: totalSeconds)
        }

        advanceToNextSession()
    }

    private func advanceToNextSession() {
        if currentSessionType == .focus {
            if completedSessions % configuration.sessionsUntilLongBreak == 0 {
                currentSessionType = .longBreak
            } else {
                currentSessionType = .shortBreak
            }
        } else {
            currentSessionType = .focus
        }

        totalSeconds = configuration.seconds(for: currentSessionType)
        remainingSeconds = totalSeconds

        let shouldAutoStart = currentSessionType == .focus
            ? configuration.autoStartFocus
            : configuration.autoStartBreaks

        if shouldAutoStart {
            timerState = .idle
            start()
        } else {
            timerState = .idle
        }
    }

    private func resetTimer() {
        totalSeconds = configuration.seconds(for: currentSessionType)
        remainingSeconds = totalSeconds
    }

    // MARK: - Persistence

    private func saveSession(completed: Bool, elapsedSeconds: Int) {
        guard let context = modelContext else { return }

        let session = FocusSession(
            durationSeconds: totalSeconds,
            sessionType: currentSessionType.rawValue,
            category: selectedCategory.rawValue
        )

        if completed {
            session.complete()
        } else {
            session.cancel(elapsedSeconds: elapsedSeconds)
        }

        context.insert(session)
        try? context.save()
    }

    private func loadTodaysStats() {
        guard let context = modelContext else { return }

        let startOfToday = Date().startOfDay
        let predicate = #Predicate<FocusSession> {
            $0.startDate >= startOfToday && $0.sessionType == "focus" && $0.isCompleted
        }

        let descriptor = FetchDescriptor<FocusSession>(predicate: predicate)

        if let sessions = try? context.fetch(descriptor) {
            todaysSessions = sessions.count
            todaysFocusMinutes = sessions.reduce(0) { $0 + $1.completedMinutes }
            completedSessions = sessions.count
        }
    }

    private func saveConfiguration() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: "timerConfiguration")
        }
    }

    // MARK: - Notifications

    private func scheduleNotification() {
        let title: String
        let body: String

        switch currentSessionType {
        case .focus:
            title = "Focus Session Complete!"
            body = "Great work! Time for a break."
        case .shortBreak:
            title = "Break's Over"
            body = "Ready to focus again?"
        case .longBreak:
            title = "Long Break Complete"
            body = "Feeling refreshed? Let's get back to it!"
        }

        NotificationManager.shared.scheduleTimerEnd(
            in: TimeInterval(remainingSeconds),
            title: title,
            body: body
        )
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.backgroundDate = Date()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  let bgDate = self.backgroundDate,
                  self.timerState == .running else { return }

            let elapsed = Int(Date().timeIntervalSince(bgDate))
            self.remainingSeconds = max(0, self.remainingSeconds - elapsed)
            self.backgroundDate = nil

            if self.remainingSeconds == 0 {
                self.handleSessionComplete()
            }
        }
    }

    // MARK: - Streak

    func calculateStreak() {
        guard let context = modelContext else { return }

        var streak = 0
        var checkDate = Date()

        while true {
            let dayStart = checkDate.startOfDay
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!

            let predicate = #Predicate<FocusSession> {
                $0.startDate >= dayStart && $0.startDate < dayEnd && $0.isCompleted && $0.sessionType == "focus"
            }

            let descriptor = FetchDescriptor<FocusSession>(predicate: predicate)

            if let sessions = try? context.fetch(descriptor), !sessions.isEmpty {
                streak += 1
                checkDate = checkDate.daysAgo(1)
            } else {
                if !checkDate.isToday {
                    break
                }
                checkDate = checkDate.daysAgo(1)
            }
        }

        currentStreak = streak
    }
}
