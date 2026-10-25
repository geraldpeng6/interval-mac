import XCTest
@testable import PauseCore

final class DecisionEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var instant: TimeInterval { now.timeIntervalSince1970 }
    private func dueEngine() -> DecisionEngine {
        var engine = DecisionEngine(); engine.screenSinceEyeRest = 1200
        return engine
    }
    private func preferences() -> Preferences {
        var p = Preferences(); p.monitoring = true; p.quietHours = false
        return p
    }
    func testReminderWaitsForNaturalGapAndDoesNotInterruptTyping() {
        let engine = dueEngine(); var signal = Signal(); signal.keysPerMinute = 210
        let day = DayRecord(date: now)
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: preferences(), signal: signal, day: day).kind, .wait)
        signal.idleSeconds = 12; signal.keysPerMinute = 20
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: preferences(), signal: signal, day: day).kind, .rest(.eyes))
    }
    func testProtectedContextsAlwaysWinEvenWhenVeryOverdue() {
        var engine = dueEngine(); engine.screenSinceEyeRest = 12000
        var signal = Signal(); signal.idleSeconds = 12
        let day = DayRecord(date: now)
        for context in [Context.meeting, .movie] {
            var p = preferences(); p.context = context
            XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: day).kind, .wait)
        }
        for category in [AppCategory.meeting, .media] {
            signal.category = category
            XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: preferences(), signal: signal, day: day).kind, .wait)
        }
        signal.category = .neutral; signal.fullscreen = true
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: preferences(), signal: signal, day: day).kind, .wait)
        signal.fullscreen = false; signal.microphoneBusy = true
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: preferences(), signal: signal, day: day).kind, .wait)
        signal.microphoneBusy = false; signal.screenAvailable = false
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: preferences(), signal: signal, day: day).kind, .wait)
    }
    func testDisabledDetectionDoesNotInspectCategoryAndManualProtectionStillWins() {
        var p = preferences(); p.contextDetection = false
        var signal = Signal(); signal.category = .meeting; signal.idleSeconds = 15
        XCTAssertEqual(dueEngine().decide(now: instant, hour: 12, preferences: p, signal: signal, day: .init(date: now)).kind, .rest(.eyes))
        p.context = .movie
        XCTAssertEqual(dueEngine().decide(now: instant, hour: 12, preferences: p, signal: signal, day: .init(date: now)).kind, .wait)
    }
    func testSnoozeCooldownQuietHoursAndDisabledItemsSuppressReminders() {
        var signal = Signal(); signal.idleSeconds = 12
        var engine = dueEngine(); engine.snoozeUntil = instant + 300
        let day = DayRecord(date: now)
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: preferences(), signal: signal, day: day).kind, .wait)
        engine.snoozeUntil = -.greatestFiniteMagnitude
        engine.offered(.init(.rest(.eyes), ""), at: instant)
        XCTAssertEqual(engine.decide(now: instant + 60, hour: 12, preferences: preferences(), signal: signal, day: day).kind, .wait)
        engine = dueEngine(); var p = preferences(); p.quietHours = true
        for hour in [22, 23, 0, 7] { XCTAssertEqual(engine.decide(now: instant, hour: hour, preferences: p, signal: signal, day: day).kind, .wait) }
        XCTAssertEqual(engine.decide(now: instant, hour: 8, preferences: p, signal: signal, day: day).kind, .rest(.eyes))
        p.routine = p.routine.map { var i = $0; i.enabled = false; return i }
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: day).kind, .wait)
    }
    func testHighKeyboardLoadBringsWristOpportunityForwardButNeverInterruptsBurst() {
        var engine = DecisionEngine(); engine.exposure[.wrists] = 2200
        var p = preferences(); p.routine = [.init(.wrists, interval: 50, duration: 60, target: 0)]
        var signal = Signal(); signal.idleSeconds = 10; signal.keysPerMinute = 200
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: .init(date: now)).kind, .wait)
        // Recent high load remains relevant after a typing burst ends.
        _ = engine.advance(seconds: 5, signal: signal)
        signal.keysPerMinute = 20
        _ = engine.advance(seconds: 5, signal: signal)
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: .init(date: now)).kind, .rest(.wrists))
    }
    func testCompletionClearsOnlyRelevantActivityDebt() {
        var engine = dueEngine(); engine.exposure = [.wrists: 3000, .shoulders: 3000]
        engine.complete(.eyes)
        XCTAssertEqual(engine.screenSinceEyeRest, 0)
        var p = preferences(); p.routine = [.init(.wrists, interval: 50, duration: 60, target: 0)]
        var signal = Signal(); signal.idleSeconds = 10
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: .init(date: now)).kind, .rest(.wrists))
        engine.complete(.wrists)
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: .init(date: now)).kind, .wait)
    }
    func testSleepAndLongAbsenceAreNeverAddedAsScreenTime() {
        var engine = dueEngine(); var signal = Signal()
        XCTAssertEqual(engine.advance(seconds: 3600, signal: signal), 0)
        signal.screenAvailable = false
        XCTAssertEqual(engine.advance(seconds: 5, signal: signal), 0)
        XCTAssertEqual(engine.screenSinceEyeRest, 1_200) // a brief lock is absence, not yet rest
        for _ in 0..<3 { _ = engine.advance(seconds: 5, signal: signal) } // cumulative 20 s away
        XCTAssertEqual(engine.screenSinceEyeRest, 0)
        signal.screenAvailable = true; signal.idleSeconds = 600
        XCTAssertEqual(engine.advance(seconds: 5, signal: signal), 0)
        signal.idleSeconds = 0
        XCTAssertEqual(engine.advance(seconds: 5, signal: signal), 5)
        XCTAssertEqual(engine.screenSinceEyeRest, 5)
    }
    func testRefocusRequiresExplicitStudyModeAndSustainedUserMarkedDistraction() {
        let engine = DecisionEngine(); var signal = Signal(); signal.category = .distracting; signal.categorySeconds = 100
        var p = preferences(); let day = DayRecord(date: now)
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: day).kind, .wait)
        p.context = .study
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: day).kind, .refocus)
        signal.categorySeconds = 30
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: day).kind, .wait)
    }
    func testUserRulesOverrideConservativeBuiltInCategories() {
        XCTAssertEqual(Classifier.category(bundleID: "us.zoom.xos", rules: []), .meeting)
        XCTAssertEqual(Classifier.category(bundleID: "com.apple.Safari", rules: []), .neutral)
        XCTAssertEqual(Classifier.category(bundleID: "us.zoom.xos", rules: [.init(bundleID: "us.zoom.xos", category: .productive)]), .productive)
    }
    func testBriefAbsencePausesAccumulationButPreservesDueReminders() {
        var engine = DecisionEngine()
        engine.exposure[.wrists] = 3_200
        engine.screenSinceEyeRest = 1_200
        var burst = Signal(); burst.idleSeconds = 1; burst.keysPerMinute = 250
        _ = engine.advance(seconds: 10, signal: burst)
        var locked = Signal(); locked.screenAvailable = false
        for _ in 0..<3 { XCTAssertEqual(engine.advance(seconds: 5, signal: locked), 0) } // 15 s away
        var back = Signal(); back.idleSeconds = 12
        XCTAssertEqual(engine.advance(seconds: 5, signal: back), 5)
        XCTAssertEqual(engine.screenSinceEyeRest, 1_215) // 1_200 + 10 active + 5 resumed, lock frozen
        var p = preferences(); p.routine = [.init(.wrists, interval: 50, duration: 60, target: 0)]
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: back, day: .init(date: now)).kind, .rest(.wrists))
    }
    func testEyeRestCreditRequiresTwentySecondsOfUnavailableScreen() {
        var engine = DecisionEngine()
        engine.screenSinceEyeRest = 1_200
        engine.exposure[.wrists] = 3_200
        var locked = Signal(); locked.screenAvailable = false
        for _ in 0..<3 { _ = engine.advance(seconds: 5, signal: locked) }
        XCTAssertEqual(engine.screenSinceEyeRest, 1_200) // 15 s away is not eye rest yet
        _ = engine.advance(seconds: 5, signal: locked) // cumulative 20 s
        XCTAssertEqual(engine.screenSinceEyeRest, 0)
        XCTAssertEqual(engine.exposure[.wrists] ?? 0, 3_200) // body debt needs 300 s away
    }
    func testReturningFromLockDoesNotInheritStaleActivityDebtOrTypingPeak() {
        var engine = DecisionEngine()
        var burst = Signal(); burst.idleSeconds = 1; burst.keysPerMinute = 250
        _ = engine.advance(seconds: 10, signal: burst)
        var locked = Signal(); locked.screenAvailable = false
        for _ in 0..<60 { XCTAssertEqual(engine.advance(seconds: 5, signal: locked), 0) } // 300 s away
        var back = Signal(); back.idleSeconds = 12; back.keysPerMinute = 30
        XCTAssertEqual(engine.advance(seconds: 5, signal: back), 5)
        XCTAssertEqual(engine.exposure[.wrists] ?? 0, 5) // one resumed sample; pre-absence debt gone
        XCTAssertEqual(engine.recentTypingPeak, 30) // current typing only; the 250 burst is not inherited
        XCTAssertEqual(engine.screenSinceEyeRest, 5) // only the active sample after return
        var p = preferences(); p.routine = [.init(.wrists, interval: 50, duration: 60, target: 0)]
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: back, day: .init(date: now)).kind, .wait)
    }
    func testCoalescedSleepResetsDebtButNeverCountsAsScreenTime() {
        var engine = DecisionEngine()
        engine.exposure[.wrists] = 3_000
        engine.recentTypingPeak = 250
        engine.screenSinceEyeRest = 1_200
        var away = Signal(); away.screenAvailable = false
        XCTAssertEqual(engine.advance(seconds: 28_800, signal: away), 0)
        XCTAssertTrue(engine.exposure.isEmpty)
        XCTAssertEqual(engine.recentTypingPeak, 0)
        XCTAssertEqual(engine.screenSinceEyeRest, 0)
    }
    func testCoalescedAvailableGapPreservesDebtAndAddsZeroScreenTime() {
        var engine = DecisionEngine()
        engine.exposure[.wrists] = 3_200
        engine.recentTypingPeak = 250
        engine.screenSinceEyeRest = 1_200
        XCTAssertEqual(engine.advance(seconds: 3_600, signal: Signal()), 0) // available screen, no idle evidence
        XCTAssertEqual(engine.screenSinceEyeRest, 1_200)
        XCTAssertEqual(engine.exposure[.wrists] ?? 0, 3_200)
        XCTAssertEqual(engine.recentTypingPeak, 250)
        var p = preferences(); p.routine = [.init(.wrists, interval: 50, duration: 60, target: 0)]
        var back = Signal(); back.idleSeconds = 12
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: back, day: .init(date: now)).kind, .rest(.wrists))
    }
    func testLongIdlePauseRetiresStaleTypingPeakForWristTiming() {
        var engine = DecisionEngine()
        var burst = Signal(); burst.idleSeconds = 1; burst.keysPerMinute = 250
        _ = engine.advance(seconds: 10, signal: burst)
        var away = Signal(); away.idleSeconds = 600
        _ = engine.advance(seconds: 5, signal: away)
        engine.exposure[.wrists] = 2_200
        var back = Signal(); back.idleSeconds = 12; back.keysPerMinute = 30
        var p = preferences(); p.routine = [.init(.wrists, interval: 50, duration: 60, target: 0)]
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: back, day: .init(date: now)).kind, .wait)
    }
    func testDailyGoalCanBringAQuietOpportunityForward() {
        var engine = DecisionEngine(); engine.exposure[.wrists] = 600
        var p = preferences(); p.routine = [.init(.wrists, interval: 50, duration: 60, target: 8)]
        var day = DayRecord(date: now); day.screenSeconds = 7 * 3600
        var signal = Signal(); signal.idleSeconds = 12
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: day).kind, .rest(.wrists))
        day.completed[Activity.wrists.rawValue] = 8
        XCTAssertEqual(engine.decide(now: instant, hour: 12, preferences: p, signal: signal, day: day).kind, .wait)
    }
}
