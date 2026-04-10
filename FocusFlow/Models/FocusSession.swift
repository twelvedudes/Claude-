import Foundation
import SwiftData

@Model
final class FocusSession {
    var id: UUID
    var startDate: Date
    var endDate: Date?
    var durationSeconds: Int
    var completedSeconds: Int
    var sessionType: String // "focus", "shortBreak", "longBreak"
    var isCompleted: Bool
    var category: String
    var note: String

    init(
        durationSeconds: Int,
        sessionType: String = "focus",
        category: String = "General",
        note: String = ""
    ) {
        self.id = UUID()
        self.startDate = Date()
        self.endDate = nil
        self.durationSeconds = durationSeconds
        self.completedSeconds = 0
        self.sessionType = sessionType
        self.isCompleted = false
        self.category = category
        self.note = note
    }

    var durationMinutes: Int {
        durationSeconds / 60
    }

    var completedMinutes: Int {
        completedSeconds / 60
    }

    var completionPercentage: Double {
        guard durationSeconds > 0 else { return 0 }
        return Double(completedSeconds) / Double(durationSeconds)
    }

    func complete() {
        endDate = Date()
        isCompleted = true
        if let start = Optional(startDate), let end = endDate {
            completedSeconds = Int(end.timeIntervalSince(start))
        }
    }

    func cancel(elapsedSeconds: Int) {
        endDate = Date()
        isCompleted = false
        completedSeconds = elapsedSeconds
    }
}

enum SessionType: String, CaseIterable, Codable {
    case focus = "focus"
    case shortBreak = "shortBreak"
    case longBreak = "longBreak"

    var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }

    var icon: String {
        switch self {
        case .focus: return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer"
        case .longBreak: return "figure.walk"
        }
    }

    var defaultColor: String {
        switch self {
        case .focus: return "AccentColor"
        case .shortBreak: return "green"
        case .longBreak: return "blue"
        }
    }
}

enum FocusCategory: String, CaseIterable, Codable, Identifiable {
    case general = "General"
    case work = "Work"
    case study = "Study"
    case creative = "Creative"
    case exercise = "Exercise"
    case reading = "Reading"
    case meditation = "Meditation"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "circle.fill"
        case .work: return "briefcase.fill"
        case .study: return "book.fill"
        case .creative: return "paintbrush.fill"
        case .exercise: return "figure.run"
        case .reading: return "text.book.closed.fill"
        case .meditation: return "leaf.fill"
        }
    }

    var color: String {
        switch self {
        case .general: return "gray"
        case .work: return "blue"
        case .study: return "purple"
        case .creative: return "orange"
        case .exercise: return "green"
        case .reading: return "brown"
        case .meditation: return "teal"
        }
    }
}
