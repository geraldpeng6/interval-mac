import XCTest
@testable import Pause
import PauseCore

/// Contracts for the fullscreen guide's testable layer: the derived step state
/// (FullscreenGuide.swift), the pause-cover phrasing, the finished-view exit,
/// and the lockstep between SessionEngine's tick output and what the guide
/// presents. No panels, no app activation, no sensors — the controller/window
/// layer is pure presentation and stays untested.
@MainActor
final class FullscreenGuideTests: XCTestCase {
    // MARK: - Derived step index from global progress

    /// `derivedStepIndex` walks the activity's weighted step lengths, so its
    /// boundaries are the weighted ones (12/45 s for pelvic at 60 s), not the
    /// equal-division ones (20/40 s) — equal division desynced the staged step
    /// from the caption and the rail whenever weights were uneven. The min()
    /// clamp keeps the index inside the per-step arrays at the progress → 1
    /// boundary (RoutineView.instruction precedent).
    func testDerivedStepIndexNeverReachesStepCount() {
        XCTAssertEqual(derivedStepIndex(activity: .shoulders, durationSeconds: 60, progress: 0), 0)
        XCTAssertEqual(derivedStepIndex(activity: .shoulders, durationSeconds: 60, progress: 0.24), 0)
        XCTAssertEqual(derivedStepIndex(activity: .shoulders, durationSeconds: 60, progress: 0.25), 1)
        XCTAssertEqual(derivedStepIndex(activity: .shoulders, durationSeconds: 60, progress: 0.5), 1)
        XCTAssertEqual(derivedStepIndex(activity: .shoulders, durationSeconds: 60, progress: 0.99), 2)
        XCTAssertEqual(derivedStepIndex(activity: .shoulders, durationSeconds: 60, progress: 1), 2, "the final step owns the progress→1 boundary")
        XCTAssertEqual(derivedStepIndex(activity: .shoulders, durationSeconds: 60, progress: 1.5), 2, "an overshoot must clamp, not overflow")
        for activity in Activity.allCases {
            XCTAssertEqual(derivedStepIndex(activity: activity, durationSeconds: 60, progress: 1),
                           activity.steps.count - 1, "\(activity.rawValue): the last step owns the progress → 1 boundary")
        }
        XCTAssertEqual(derivedStepIndex(activity: .shoulders, durationSeconds: 60, progress: -0.1), 0, "a negative progress clamps to the first step")
    }

    func testDerivedStepIndexIsMonotonicInProgress() {
        var previous = 0
        for step in 0...100 {
            let progress = Double(step) / 100
            let index = derivedStepIndex(activity: .wrists, durationSeconds: 60, progress: progress)
            XCTAssertGreaterThanOrEqual(index, previous, "progress \(progress)")
            XCTAssertLessThan(index, Activity.wrists.steps.count, "progress \(progress)")
            previous = index
        }
    }

    /// The displayed step and the "这一步 · 约 N 秒" caption derive from the
    /// same weighted math: across every second of every activity's default run,
    /// the caption must never read 0 while its step still has a full second of
    /// weighted time left. Equal-division derivation failed this for pelvic
    /// (seconds 12–19 of 60 pinned "约 0 秒") and shoulders (15–19).
    func testCaptionNeverReadsZeroWhileTheStepStillHasWeightedTime() {
        for activity in Activity.allCases {
            let duration = RoutineItem.defaults.first(where: { $0.activity == activity })?.durationSeconds ?? 60
            for second in 0..<duration {
                let progress = 1 - Double(duration - second) / Double(duration)
                let index = derivedStepIndex(activity: activity, durationSeconds: duration, progress: progress)
                let caption = derivedStepRemaining(activity: activity, durationSeconds: duration, progress: progress, stepIndex: index)
                XCTAssertGreaterThan(caption, 0, "\(activity.rawValue) at \(second)s/\(duration)s: step \(index + 1) is still on stage")
            }
        }
    }

    /// Uneven weights: the staged step must switch exactly at each weighted
    /// boundary. Pelvic at 60 s carries [12, 33, 15] — the old equal-division
    /// derivation switched at 20/40 s instead of 12/45 s.
    func testPelvicStepBoundariesFollowTheWeightedShares() {
        let duration = 60
        func index(atSecond s: Double) -> Int {
            derivedStepIndex(activity: .pelvic, durationSeconds: duration, progress: s / Double(duration))
        }
        XCTAssertEqual(index(atSecond: 0), 0)
        XCTAssertEqual(index(atSecond: 11.9), 0, "step ① owns up to its 12 s weighted length")
        XCTAssertEqual(index(atSecond: 12.1), 1, "step ② starts right after the weighted boundary, not the equal-division one")
        XCTAssertEqual(index(atSecond: 44.9), 1, "step ② runs 33 s (12 → 45), far past the equal-division 40 s mark")
        XCTAssertEqual(index(atSecond: 45.1), 2)
        XCTAssertEqual(index(atSecond: 59.9), 2, "the last step holds to the end")
    }

    // MARK: - Normalized per-step durations

    /// Raw weights are absolute shares: dividing by their sum (never by 1) is
    /// what makes wrists' [1,1,1,1] four equal quarters instead of "each step
    /// the whole duration" (Models.swift stepWeights contract). ArchiveTests
    /// pins the share arithmetic; this pins the consumer's duration output —
    /// the per-step lengths the fullscreen captions and rail are built from.
    func testNormalizedDurationsSumToTheActivityDuration() {
        for activity in Activity.allCases {
            for duration in [activity.minimumDuration, 60, 300] {
                let durations = normalizedStepDurations(activity: activity, durationSeconds: duration)
                XCTAssertEqual(durations.count, activity.steps.count, "\(activity.rawValue)")
                XCTAssertEqual(durations.reduce(0, +), Double(duration), accuracy: 0.0001, "\(activity.rawValue) \(duration)s")
            }
        }
        XCTAssertTrue(normalizedStepDurations(activity: .wrists, durationSeconds: 60).allSatisfy { $0 > 0 })
    }

    /// Wrists' step texts promise "至少 15 秒" per arm; the default 60 s duration
    /// must deliver exactly that — the caption the fullscreen view displays.
    /// (Duration clamps at ≥ 60 s in normalize(), so every step is ≥ 15 s at
    /// any configuration and the "at least" promise always holds.)
    func testWristsDefaultDurationsMatchThePromisedFifteenSeconds() {
        XCTAssertEqual(normalizedStepDurations(activity: .wrists, durationSeconds: 60), [15, 15, 15, 15])
    }

    // MARK: - Step caption ("这一步 · 约 N 秒")

    /// The caption reads full seconds. Only dyadic checkpoints are pinned:
    /// mid-step seconds carry float noise (elapsed = 1 − r/60 is inexact), and
    /// the raw ceil of that noise is deterministic but not a contract. Pinned:
    /// a fresh step starts at its full length, each boundary resets the caption
    /// to the next step's length, the step the clock just left reads 0, a
    /// completed step reads 0 (never negative), and an out-of-range index is a
    /// no-op instead of a crash.
    func testStepRemainingCaptionIsFullSeconds() {
        XCTAssertEqual(derivedStepRemaining(activity: .wrists, durationSeconds: 60, progress: 0, stepIndex: 0), 15, "a fresh step starts at its full length")
        XCTAssertEqual(derivedStepRemaining(activity: .wrists, durationSeconds: 60, progress: 0.25, stepIndex: 1), 15, "each boundary resets the caption to the new step's length")
        XCTAssertEqual(derivedStepRemaining(activity: .wrists, durationSeconds: 60, progress: 0.25, stepIndex: 0), 0, "the step the clock just left reads 0")
        XCTAssertEqual(derivedStepRemaining(activity: .wrists, durationSeconds: 60, progress: 0.5, stepIndex: 2), 15)
        XCTAssertEqual(derivedStepRemaining(activity: .wrists, durationSeconds: 60, progress: 0.5, stepIndex: 1), 0)
        XCTAssertEqual(derivedStepRemaining(activity: .wrists, durationSeconds: 60, progress: 1, stepIndex: 3), 0, "a completed step reads 0, never negative")
        XCTAssertEqual(derivedStepRemaining(activity: .wrists, durationSeconds: 60, progress: 0, stepIndex: 4), 0, "an out-of-range step index is a no-op, not a crash (wrists has 4 steps)")
        // Within one step the caption is non-increasing and bounded by the
        // step's normalized length — for every progress, not just checkpoints.
        for step in 0...1000 {
            let progress = Double(step) / 1000
            let caption = derivedStepRemaining(activity: .wrists, durationSeconds: 60, progress: progress, stepIndex: 0)
            XCTAssertGreaterThanOrEqual(caption, 0, "progress \(progress)")
            XCTAssertLessThanOrEqual(caption, 15, "progress \(progress)")
        }
    }

    /// The stand caption across the full 300 s engine trace. With weighted
    /// derivation the displayed index and the caption switch at the same
    /// weighted boundary (30 s in), so the caption inside step ② starts near
    /// its full 225 s and counts down monotonically. What must hold everywhere:
    /// 0 ≤ caption ≤ 225 (the largest weighted step length); and the fresh
    /// session reads exactly the promised "约 30 秒" (progress 0 is exact).
    func testStandCaptionsAcrossTheEngineTickTrace() {
        let maxStepLength = normalizedStepDurations(activity: .stand, durationSeconds: 300).max()!
        for remaining in stride(from: 300.0, through: 0, by: -1) {
            let progress = 1 - remaining / 300.0
            let index = derivedStepIndex(activity: .stand, durationSeconds: 300, progress: progress)
            let caption = derivedStepRemaining(activity: .stand, durationSeconds: 300, progress: progress, stepIndex: index)
            XCTAssertGreaterThanOrEqual(caption, 0, "remaining \(remaining)")
            XCTAssertLessThanOrEqual(caption, Int(maxStepLength.rounded(.up)), "remaining \(remaining)")
        }
        XCTAssertEqual(derivedStepRemaining(activity: .stand, durationSeconds: 300, progress: 0, stepIndex: 0), 30,
                       "the stand-up step opens with its promised 30 s caption")
    }

    // MARK: - Engine → presentation lockstep

    /// The guide shows no per-step engine state: the displayed step is derived
    /// from the engine's published remaining clock. Drive a real SessionEngine
    /// tick-by-tick and confirm the derived index crosses each 15 s quarter
    /// exactly where the engine does — 60 published frames, four equal steps.
    func testFullscreenStepIndexFollowsTheEngineClock() {
        var engine = SessionEngine()
        engine.start([RoutineItem(.wrists, interval: 50, duration: 60, target: 1)])
        var derivedIndexes: [Int] = [0]
        for _ in 0..<60 {
            _ = engine.tick(elapsed: 1, screenAvailable: true)
            if engine.isActive {
                derivedIndexes.append(derivedStepIndex(activity: .wrists, durationSeconds: 60, progress: 1 - engine.remaining / 60))
            }
        }
        XCTAssertTrue(engine.isFinished, "60 × 1 s ticks complete the 60 s activity")
        XCTAssertEqual(derivedIndexes, Array(repeating: 0, count: 15)
            + Array(repeating: 1, count: 15)
            + Array(repeating: 2, count: 15)
            + Array(repeating: 3, count: 15),
                       "each 15 s quarter maps to exactly one step index (60 published frames)")
    }

    /// A user pause must freeze the derived presentation: whatever ticks pass
    /// while paused, the staged step and remaining caption stay put.
    func testPausedEngineFreezesTheDerivedStep() {
        var engine = SessionEngine()
        engine.start([RoutineItem(.eyes, interval: 20, duration: 20, target: 1)])
        _ = engine.tick(elapsed: 3, screenAvailable: true)
        let frozenRemaining = engine.remaining
        engine.pause()
        for _ in 0..<10 {
            _ = engine.tick(elapsed: 2, screenAvailable: true)
            XCTAssertEqual(engine.remaining, frozenRemaining, accuracy: 0.0001, "a paused clock must not advance")
            XCTAssertEqual(derivedStepIndex(activity: .eyes, durationSeconds: 20, progress: 1 - engine.remaining / 20), 0, "a paused session keeps staging the same step")
        }
        engine.resume()
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        XCTAssertEqual(derivedStepIndex(activity: .eyes, durationSeconds: 20, progress: 1 - engine.remaining / 20), 0)
    }

    /// Lock mid-activity: the engine's automatic screen-unavailable pause shows
    /// the same staged step as before the lock, and resumes on exactly that
    /// step when the screen returns (the clock really stopped; nothing jumps).
    func testScreenUnavailablePauseResumesOnTheSameStep() {
        var engine = SessionEngine()
        engine.start([RoutineItem(.eyes, interval: 20, duration: 20, target: 1)])
        _ = engine.tick(elapsed: 3, screenAvailable: true)
        let stepBeforeLock = derivedStepIndex(activity: .eyes, durationSeconds: 20, progress: 1 - engine.remaining / 20)
        XCTAssertTrue(engine.tick(elapsed: 5, screenAvailable: false).isEmpty)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(derivedStepIndex(activity: .eyes, durationSeconds: 20, progress: 1 - engine.remaining / 20), stepBeforeLock, "a locked screen shows the same staged step")
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        XCTAssertFalse(engine.isPaused, "the automatic pause clears on its own")
        XCTAssertEqual(derivedStepIndex(activity: .eyes, durationSeconds: 20, progress: 1 - engine.remaining / 20), stepBeforeLock)
    }

    // MARK: - Pause cover phrasing

    /// Each pause reason gets its own line on the cover (PausedOverlayView);
    /// every case — including the transient nil — must phrase something, and
    /// the three real reasons must read differently from each other.
    func testPauseCoverSubtitleMapsEveryReason() {
        let reasons: [SessionEngine.PauseReason?] = [.user, .screenUnavailable, .timingGap, nil]
        let subtitles = reasons.map { pauseCoverSubtitle(reason: $0) }
        for (reason, subtitle) in zip(reasons, subtitles) {
            XCTAssertFalse(subtitle.isEmpty, "\(String(describing: reason)) must phrase something")
        }
        XCTAssertNotEqual(subtitles[0], subtitles[1], "a user pause and a locked screen read differently")
        XCTAssertNotEqual(subtitles[0], subtitles[2])
        XCTAssertNotEqual(subtitles[1], subtitles[2])
    }

    // MARK: - Session start → fullscreen, cancel → exit

    /// Test-bundle safe shim: AppStore.openMainWindow dereferences the NSApp
    /// global, which is nil in a plain XCTest bundle (no NSApplication.shared
    /// has been created). Creating it here once is inert — no windows, no
    /// run loop, no event monitors — and matches how the production process
    /// always has the object before any session starts.
    private static func makeAppObject() {
        _ = NSApplication.shared
    }

    /// Isolated storage per store: AppStore's default fileURL points at the
    /// user's real ~/Library/Application Support/Interval/state.json, and
    /// instantiating it loads that archive (and its init-time sensors/timer
    /// setup). Injecting a fresh temporary file keeps these tests off real
    /// user data — including any future async test whose 1 s tick could run
    /// sample() → save().
    private static func makeStore() -> AppStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("interval-fullscreen-guide-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
        return AppStore(storageURL: url)
    }

    /// The finished cover's "回到刚才的事" button means "end this group":
    /// cancelSession must clear every published session mirror in one call —
    /// that is the exact state the controller's sync reads to close the panel
    /// and the state SessionGuideView re-renders from (AppStore.syncSession).
    func testCancelSessionClearsAllPublishedSessionState() {
        Self.makeAppObject()
        let store = Self.makeStore()
        store.startSession(activities: [.eyes])
        XCTAssertTrue(store.sessionActive)
        store.cancelSession()
        XCTAssertFalse(store.sessionActive, "the engine is cancelled")
        XCTAssertFalse(store.sessionFinished, "a cancelled group is not a finished one")
        XCTAssertFalse(store.fullscreenGuideVisible, "the fullscreen guide closes with the session")
        XCTAssertTrue(store.session.isEmpty, "the published session list is cleared")
        XCTAssertEqual(store.sessionRemaining, 0, accuracy: 0.0001)
        XCTAssertNil(store.sessionPauseReason, "no stale pause cover survives")
    }

    /// Starting a session publishes a coherent first frame: the engine started,
    /// the fullscreen guide is flagged visible, and the published fields carry
    /// the group's first item with its full duration (what the guide renders).
    func testStartSessionPublishesCoherentFirstFrameAndFullscreenFlag() {
        Self.makeAppObject()
        let store = Self.makeStore()
        store.startSession(activities: [.eyes])
        XCTAssertTrue(store.sessionActive)
        XCTAssertTrue(store.fullscreenGuideVisible, "starting a session shows the fullscreen guide")
        XCTAssertEqual(store.session.count, 1)
        XCTAssertEqual(store.session.first?.activity, .eyes)
        XCTAssertEqual(store.sessionRemaining, 20, accuracy: 0.0001, "the first frame starts at the full guided duration")
        XCTAssertEqual(store.sessionIndex, 0)
        XCTAssertFalse(store.sessionPaused)
        XCTAssertNil(store.sessionPauseReason)
        // The guide derives its progress from exactly these two fields.
        XCTAssertEqual(1 - store.sessionRemaining / Double(store.session[0].durationSeconds), 0, accuracy: 0.0001)
    }

    /// showFullscreenGuide is a no-op without a session: no stale fullscreen
    /// flag from a stray call, and hideFullscreenGuide is idempotent (Esc can
    /// arrive through three paths — AppStore comments call this out).
    func testFullscreenGuideFlagLifecycleIsGuardedAndIdempotent() {
        let store = Self.makeStore()
        store.showFullscreenGuide()
        XCTAssertFalse(store.fullscreenGuideVisible, "no session, no fullscreen guide")
        store.hideFullscreenGuide()
        XCTAssertFalse(store.fullscreenGuideVisible)
        Self.makeAppObject()
        store.startSession(activities: [.eyes])
        store.hideFullscreenGuide()
        store.hideFullscreenGuide()
        XCTAssertFalse(store.fullscreenGuideVisible, "a second hide must not resurrect the flag")
        XCTAssertTrue(store.sessionActive, "hiding the guide keeps the session running")
    }

    // MARK: - SF Symbol validity

    /// Every per-step symbol the fullscreen guide stages (and every activity's
    /// header symbol) must resolve in this OS's SF Symbols library: the
    /// implementation documents that a wrong name renders as nothing at all
    /// ("hand.point.up.right does not exist… verified via
    /// NSImage(systemSymbolName:) == nil"), so a name added today can regress
    /// tomorrow with no crash — this is the one test that catches it.
    func testFullscreenStepSymbolsResolveOnThisOS() {
        for activity in Activity.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: activity.symbol, accessibilityDescription: nil),
                            "\(activity.rawValue) header symbol")
            for (index, name) in activity.stepSymbols.enumerated() {
                XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                                "\(activity.rawValue) step \(index + 1) symbol")
            }
        }
        // The stages hardcode two more symbols beside the per-step arrays.
        for name in ["eye.fill", "leaf"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "hardcoded stage symbol")
        }
    }
}
