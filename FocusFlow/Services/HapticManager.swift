import UIKit

final class HapticManager {
    static let shared = HapticManager()

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let notificationFeedback = UINotificationFeedbackGenerator()

    func light() {
        lightImpact.impactOccurred()
    }

    func medium() {
        mediumImpact.impactOccurred()
    }

    func heavy() {
        heavyImpact.impactOccurred()
    }

    func selection() {
        selectionFeedback.selectionChanged()
    }

    func success() {
        notificationFeedback.notificationOccurred(.success)
    }

    func warning() {
        notificationFeedback.notificationOccurred(.warning)
    }

    func error() {
        notificationFeedback.notificationOccurred(.error)
    }

    func timerTick() {
        lightImpact.impactOccurred(intensity: 0.3)
    }

    func sessionComplete() {
        Task { @MainActor in
            heavyImpact.impactOccurred()
            try? await Task.sleep(for: .milliseconds(150))
            heavyImpact.impactOccurred()
            try? await Task.sleep(for: .milliseconds(150))
            notificationFeedback.notificationOccurred(.success)
        }
    }
}
