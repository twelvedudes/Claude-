import SwiftUI
import SwiftData

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var selectedPeriod: StatsPeriod = .week
    @Published var totalSessions: Int = 0
    @Published var totalMinutes: Int = 0
    @Published var averageSessionLength: Int = 0
    @Published var bestDay: String = "-"
    @Published var bestDayMinutes: Int = 0
    @Published var currentStreak: Int = 0
    @Published var longestStreak: Int = 0
    @Published var dailyData: [DailyStatPoint] = []
    @Published var categoryBreakdown: [CategoryStat] = []

    private var modelContext: ModelContext?

    enum StatsPeriod: String, CaseIterable {
        case week = "Week"
        case month = "Month"
        case year = "Year"
        case allTime = "All Time"
    }

    struct DailyStatPoint: Identifiable {
        let id = UUID()
        let date: Date
        let label: String
        let minutes: Int
        let sessions: Int
    }

    struct CategoryStat: Identifiable {
        let id = UUID()
        let category: FocusCategory
        let minutes: Int
        let sessions: Int
        let percentage: Double
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        loadStats()
    }

    func loadStats() {
        guard let context = modelContext else { return }

        let startDate: Date
        switch selectedPeriod {
        case .week: startDate = Date().daysAgo(7)
        case .month: startDate = Date().daysAgo(30)
        case .year: startDate = Date().daysAgo(365)
        case .allTime: startDate = Date.distantPast
        }

        let predicate = #Predicate<FocusSession> {
            $0.startDate >= startDate && $0.isCompleted && $0.sessionType == "focus"
        }

        let descriptor = FetchDescriptor<FocusSession>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startDate)]
        )

        guard let sessions = try? context.fetch(descriptor) else { return }

        totalSessions = sessions.count
        totalMinutes = sessions.reduce(0) { $0 + $1.completedMinutes }
        averageSessionLength = totalSessions > 0 ? totalMinutes / totalSessions : 0

        loadDailyData(sessions: sessions)
        loadCategoryBreakdown(sessions: sessions)
        calculateStreaks()
    }

    private func loadDailyData(sessions: [FocusSession]) {
        let days: Int
        switch selectedPeriod {
        case .week: days = 7
        case .month: days = 30
        case .year: days = 12 // months
        case .allTime: days = 30
        }

        var data: [DailyStatPoint] = []
        var bestMinutes = 0
        var bestDayLabel = "-"

        if selectedPeriod == .year {
            for i in (0..<12).reversed() {
                let date = Calendar.current.date(byAdding: .month, value: -i, to: Date()) ?? Date()
                let monthStart = date.startOfMonth
                let monthEnd = Calendar.current.date(byAdding: .month, value: 1, to: monthStart)!

                let monthSessions = sessions.filter {
                    $0.startDate >= monthStart && $0.startDate < monthEnd
                }
                let minutes = monthSessions.reduce(0) { $0 + $1.completedMinutes }
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM"
                let label = formatter.string(from: date)

                data.append(DailyStatPoint(date: date, label: label, minutes: minutes, sessions: monthSessions.count))

                if minutes > bestMinutes {
                    bestMinutes = minutes
                    bestDayLabel = label
                }
            }
        } else {
            for i in (0..<days).reversed() {
                let date = Date().daysAgo(i)
                let dayStart = date.startOfDay
                let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!

                let daySessions = sessions.filter {
                    $0.startDate >= dayStart && $0.startDate < dayEnd
                }
                let minutes = daySessions.reduce(0) { $0 + $1.completedMinutes }

                data.append(DailyStatPoint(
                    date: date,
                    label: date.dayOfWeekShort,
                    minutes: minutes,
                    sessions: daySessions.count
                ))

                if minutes > bestMinutes {
                    bestMinutes = minutes
                    bestDayLabel = date.monthDayString
                }
            }
        }

        dailyData = data
        bestDay = bestDayLabel
        bestDayMinutes = bestMinutes
    }

    private func loadCategoryBreakdown(sessions: [FocusSession]) {
        var categoryMap: [String: (minutes: Int, sessions: Int)] = [:]

        for session in sessions {
            let key = session.category
            let current = categoryMap[key] ?? (minutes: 0, sessions: 0)
            categoryMap[key] = (
                minutes: current.minutes + session.completedMinutes,
                sessions: current.sessions + 1
            )
        }

        let totalMins = max(1, categoryMap.values.reduce(0) { $0 + $1.minutes })

        categoryBreakdown = categoryMap.map { key, value in
            CategoryStat(
                category: FocusCategory(rawValue: key) ?? .general,
                minutes: value.minutes,
                sessions: value.sessions,
                percentage: Double(value.minutes) / Double(totalMins)
            )
        }.sorted { $0.minutes > $1.minutes }
    }

    private func calculateStreaks() {
        guard let context = modelContext else { return }

        var current = 0
        var longest = 0
        var checkDate = Date()

        while true {
            let dayStart = checkDate.startOfDay
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!

            let predicate = #Predicate<FocusSession> {
                $0.startDate >= dayStart && $0.startDate < dayEnd && $0.isCompleted && $0.sessionType == "focus"
            }

            let descriptor = FetchDescriptor<FocusSession>(predicate: predicate)

            if let sessions = try? context.fetch(descriptor), !sessions.isEmpty {
                current += 1
                longest = max(longest, current)
                checkDate = checkDate.daysAgo(1)
            } else {
                if !checkDate.isToday { break }
                checkDate = checkDate.daysAgo(1)
            }
        }

        currentStreak = current
        longestStreak = max(longest, UserDefaults.standard.integer(forKey: "longestStreak"))
        UserDefaults.standard.set(longestStreak, forKey: "longestStreak")
    }
}
