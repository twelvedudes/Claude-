import SwiftUI
import SwiftData

@main
struct FocusFlowApp: App {
    @StateObject private var timerVM = TimerViewModel()
    @StateObject private var storeManager = StoreManager.shared
    @StateObject private var soundManager = SoundManager.shared
    @StateObject private var themeManager = ThemeManager.shared

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([FocusSession.self])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            Group {
                if hasSeenOnboarding {
                    ContentView()
                } else {
                    OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
                }
            }
            .environmentObject(timerVM)
            .environmentObject(storeManager)
            .environmentObject(soundManager)
            .environmentObject(themeManager)
            .modelContainer(sharedModelContainer)
            .onAppear {
                timerVM.setModelContext(sharedModelContainer.mainContext)
                timerVM.calculateStreak()
                Task {
                    _ = await NotificationManager.shared.requestAuthorization()
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
