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
