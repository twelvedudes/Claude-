import Foundation

struct TimerConfiguration: Codable, Equatable {
    var focusMinutes: Int
    var shortBreakMinutes: Int
    var longBreakMinutes: Int
    var sessionsUntilLongBreak: Int
    var autoStartBreaks: Bool
    var autoStartFocus: Bool

    static let free = TimerConfiguration(
        focusMinutes: 25,
        shortBreakMinutes: 5,
        longBreakMinutes: 15,
        sessionsUntilLongBreak: 4,
        autoStartBreaks: false,
        autoStartFocus: false
    )

    static let defaultPro = TimerConfiguration(
        focusMinutes: 25,
        shortBreakMinutes: 5,
        longBreakMinutes: 15,
        sessionsUntilLongBreak: 4,
        autoStartBreaks: true,
        autoStartFocus: true
    )

    var focusSeconds: Int { focusMinutes * 60 }
    var shortBreakSeconds: Int { shortBreakMinutes * 60 }
    var longBreakSeconds: Int { longBreakMinutes * 60 }

    func seconds(for type: SessionType) -> Int {
        switch type {
        case .focus: return focusSeconds
        case .shortBreak: return shortBreakSeconds
        case .longBreak: return longBreakSeconds
        }
    }
}

struct DailyGoal: Codable {
    var targetSessions: Int
    var targetMinutes: Int

    static let `default` = DailyGoal(targetSessions: 8, targetMinutes: 200)
}
