@preconcurrency import AVFoundation
import Foundation
import Combine
import PauseCore

/// One built-in soundscape, backed by a bundled loopable .caf.
enum Soundscape: String, CaseIterable, Identifiable, Equatable {
    case none
    case whiteNoise = "white-noise"
    case rain
    case forest
    case eveningPad = "evening-pad"

    public var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "关闭"
        case .whiteNoise: "白噪声"
        case .rain: "雨声"
        case .forest: "林间"
        case .eveningPad: "暮色音乐"
        }
    }
    var pref: SoundscapePref {
        switch self {
        case .none: .none
        case .whiteNoise: .whiteNoise
        case .rain: .rain
        case .forest: .forest
        case .eveningPad: .eveningPad
        }
    }
    static func from(_ pref: SoundscapePref) -> Self { Self(rawValue: pref.rawValue) ?? .none }
    /// File stem inside the app bundle's Resources/sounds.
    var fileStem: String { rawValue }
}

/// Plays the built-in soundscapes with fade in/out and follows the session:
/// starts with the first guided step, ducks to a whisper on pause (without
/// restarting the loop), stops when the group ends.
/// Zero dependencies (AVAudioPlayer loops a bundled file) and no network access;
/// audio never leaves the device and no playback data is stored.
@MainActor final class SoundEngine: ObservableObject {
    /// Persisted choice from preferences; observed by the settings UI.
    @Published var selection: Soundscape = .none {
        didSet { syncPlayback(fade: true) }
    }
    /// Whether sound is currently audible (playing at any level).
    @Published private(set) var audible = false
    /// Whether a guided session is running (start/stop/pause of the soundscape).
    var sessionActive = false {
        didSet { if sessionActive != oldValue { syncPlayback(fade: true) } }
    }
    var sessionPaused = false {
        didSet { if sessionPaused != oldValue { syncPlayback(fade: true) } }
    }
    private var player: AVAudioPlayer?
    private var volumeTimer: Timer?
    /// The player keeps looping through pauses so resume never restarts the file;
    /// volume drops to `pausedVolume` instead.
    private let normalVolume: Float = 0.8
    private let pausedVolume: Float = 0.12

    init() {}

    /// Stops playback and tears down the player; called on application quit.
    func stop() {
        volumeTimer?.invalidate(); volumeTimer = nil
        player?.stop(); player = nil
        audible = false
    }

    /// Reconciles the desired state (selection + session) with the player.
    private func syncPlayback(fade: Bool) {
        let wantsSound = sessionActive && selection != .none
        if wantsSound {
            if player == nil || player?.isPlaying == false {
                startPlayer(selection)
            } else if let current = currentStem, current != selection.fileStem {
                startPlayer(selection)
            }
            // A paused session ducks to a whisper instead of silencing, so the
            // ambience resumes exactly where the pause left it.
            fadeTo(target: sessionPaused ? pausedVolume : normalVolume, fade: fade)
            audible = true
        } else {
            if let player, player.isPlaying { fadeTo(target: 0, fade: fade) }
            audible = false
        }
    }

    private var currentStem: String? {
        guard let url = player?.url else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    private func startPlayer(_ soundscape: Soundscape) {
        volumeTimer?.invalidate(); volumeTimer = nil
        // Loop files live in Resources/sounds/<stem>.caf (packaged by package.sh).
        guard let url = Bundle.main.url(forResource: soundscape.fileStem, withExtension: "caf", subdirectory: "sounds")
            ?? Bundle.main.url(forResource: soundscape.fileStem, withExtension: "caf") else { return }
        let player = try? AVAudioPlayer(contentsOf: url)
        guard let player else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        // Cut the outgoing soundscape cleanly instead of letting the old player
        // die with the reference swap (an audible hard stop mid-fade).
        self.player?.stop()
        self.player = player
    }

    /// Fades the player volume to `target` over ~1.2 s. Stops the player only
    /// when fading all the way out; a pause keeps the loop running, just quieter.
    private func fadeTo(target: Float, fade: Bool) {
        guard let player else { return }
        volumeTimer?.invalidate(); volumeTimer = nil
        if !fade { player.volume = target; return }
        // The tick timer runs in .common so fades keep moving while a menu is
        // open or a modal sheet is up (scheduledTimer alone would stall there).
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let player else { return }
                let delta: Float = target > player.volume ? 0.045 : -0.045
                let next = player.volume + delta
                if abs(next - target) <= 0.05 {
                    player.volume = target
                    if target == 0 {
                        player.stop()
                        self?.player = nil
                    }
                    self?.volumeTimer = nil
                } else {
                    player.volume = next
                }
            }
        }
        volumeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
