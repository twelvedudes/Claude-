import AVFoundation
import SwiftUI

@MainActor
final class SoundManager: ObservableObject {
    static let shared = SoundManager()

    @Published var currentAmbientSound: AmbientSound? = nil
    @Published var isPlaying: Bool = false
    @Published var volume: Float = 0.5

    private var audioPlayer: AVAudioPlayer?
    private var timerEndPlayer: AVAudioPlayer?

    enum AmbientSound: String, CaseIterable, Identifiable, Codable {
        case rain = "Rain"
        case ocean = "Ocean Waves"
        case forest = "Forest"
        case fire = "Fireplace"
        case whiteNoise = "White Noise"
        case cafe = "Coffee Shop"
        case wind = "Gentle Wind"
        case stream = "Stream"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .rain: return "cloud.rain.fill"
            case .ocean: return "water.waves"
            case .forest: return "tree.fill"
            case .fire: return "flame.fill"
            case .whiteNoise: return "waveform"
            case .cafe: return "cup.and.saucer.fill"
            case .wind: return "wind"
            case .stream: return "drop.fill"
            }
        }

        var isPremium: Bool {
            switch self {
            case .rain, .whiteNoise: return false
            default: return true
            }
        }
    }

    func playAmbient(_ sound: AmbientSound) {
        currentAmbientSound = sound
        isPlaying = true
        configureAudioSession()
        // In production, load the actual audio file:
        // guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "mp3") else { return }
        // audioPlayer = try? AVAudioPlayer(contentsOf: url)
        // audioPlayer?.numberOfLoops = -1
        // audioPlayer?.volume = volume
        // audioPlayer?.play()
    }

    func stopAmbient() {
        audioPlayer?.stop()
        currentAmbientSound = nil
        isPlaying = false
    }

    func toggleAmbient(_ sound: AmbientSound) {
        if currentAmbientSound == sound && isPlaying {
            stopAmbient()
        } else {
            playAmbient(sound)
        }
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        audioPlayer?.volume = newVolume
    }

    func playTimerEnd() {
        // Play completion sound
        // guard let url = Bundle.main.url(forResource: "timer_end", withExtension: "wav") else { return }
        // timerEndPlayer = try? AVAudioPlayer(contentsOf: url)
        // timerEndPlayer?.play()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
}
