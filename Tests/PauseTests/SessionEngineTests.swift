import XCTest
@testable import Pause
import PauseCore

/// Behavior contracts for the guided activity group: what the user sees on the clock,
/// which steps get recorded as completed, and when the clock is allowed to run.
final class SessionEngineTests: XCTestCase {
    private func item(_ activity: Activity, _ duration: Int) -> RoutineItem {
        RoutineItem(activity, interval: 20, duration: duration, target: 1)
    }

    /// A running group over the first activities, one second per tick unless stated.
    private func running(_ durations: [Int]) -> SessionEngine {
        var engine = SessionEngine()
        engine.start(durations.enumerated().map { offset, duration in
            item(Activity.allCases[offset], duration)
        })
        return engine
    }

    private func drain(_ engine: inout SessionEngine) -> [SessionEngine.Event] {
        var events: [SessionEngine.Event] = []
        var ticks = 0
        while engine.isActive && ticks < 10_000 {
            events += engine.tick(elapsed: 1, screenAvailable: true)
            ticks += 1
        }
        return events
    }

    func testClockCountsOnlyMeasuredSecondsWhileRunning() {
        var engine = running([20])
        for _ in 0..<3 { XCTAssertTrue(engine.tick(elapsed: 1, screenAvailable: true).isEmpty) }
        XCTAssertEqual(engine.remaining, 17, accuracy: 0.0001)
        XCTAssertTrue(engine.isActive)
        XCTAssertFalse(engine.isFinished)
    }

    func testStepBoundaryOvershootDoesNotEatNextStepDuration() {
        var engine = running([20, 30])
        for _ in 0..<19 { _ = engine.tick(elapsed: 1, screenAvailable: true) }
        XCTAssertEqual(engine.remaining, 1, accuracy: 0.0001)
        let events = engine.tick(elapsed: 1.5, screenAvailable: true)
        XCTAssertEqual(events, [.stepCompleted(.eyes)])
        XCTAssertEqual(engine.remaining, 30, accuracy: 0.0001, "the next step must start with its full guided duration")
    }

    func testFinalStepRecordsCompletionThenFinish() {
        var engine = running([20])
        for _ in 0..<19 { XCTAssertTrue(engine.tick(elapsed: 1, screenAvailable: true).isEmpty) }
        XCTAssertEqual(engine.tick(elapsed: 1, screenAvailable: true), [.stepCompleted(.eyes), .allStepsCompleted])
        XCTAssertTrue(engine.isFinished)
        XCTAssertFalse(engine.isActive)
        XCTAssertEqual(engine.remaining, 0, accuracy: 0.0001)
        XCTAssertTrue(engine.tick(elapsed: 1, screenAvailable: true).isEmpty)
    }

    func testEventsCarryEachActivityInOrder() {
        var engine = running([20, 30])
        XCTAssertEqual(drain(&engine), [.stepCompleted(.eyes), .stepCompleted(.wrists), .allStepsCompleted])
        XCTAssertTrue(engine.isFinished)
    }

    func testUserPauseExcludesElapsedAndSurvivesScreenLossAndReturn() {
        var engine = running([20])
        engine.pause()
        _ = engine.tick(elapsed: 2, screenAvailable: false)
        _ = engine.tick(elapsed: 2, screenAvailable: true)
        XCTAssertTrue(engine.isPaused, "a pause the user asked for must survive lock/unlock")
        XCTAssertEqual(engine.remaining, 20, accuracy: 0.0001)
        engine.resume()
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        XCTAssertEqual(engine.remaining, 19, accuracy: 0.0001)
    }

    func testUserPauseSurvivesTimingGapElapsed() {
        var engine = running([20])
        engine.pause()
        _ = engine.tick(elapsed: 9, screenAvailable: true)
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        XCTAssertTrue(engine.isPaused, "a gap while user-paused must not turn into an auto-resume")
        XCTAssertEqual(engine.remaining, 20, accuracy: 0.0001)
        engine.resume()
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        XCTAssertEqual(engine.remaining, 19, accuracy: 0.0001)
    }

    func testScreenLossPausesClockAndRecoversWhenScreenReturns() {
        var engine = running([20])
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        _ = engine.tick(elapsed: 1, screenAvailable: false)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.remaining, 19, accuracy: 0.0001, "locked screen must not consume guided time")
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        XCTAssertFalse(engine.isPaused, "a pause caused by the locked screen should end when the user is back")
        XCTAssertEqual(engine.remaining, 18, accuracy: 0.0001)
    }

    func testTimerGapPausesOnceThenResumesOnSteadyClock() {
        var engine = running([20])
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        _ = engine.tick(elapsed: 9, screenAvailable: true)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.remaining, 19, accuracy: 0.0001, "an untrusted gap must not consume guided time")
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        XCTAssertFalse(engine.isPaused, "once the clock is steady again the session continues on its own")
        XCTAssertEqual(engine.remaining, 18, accuracy: 0.0001)
    }

    func testRepeatedGapsKeepClockPaused() {
        var engine = running([20])
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        _ = engine.tick(elapsed: 9, screenAvailable: true)
        _ = engine.tick(elapsed: 9, screenAvailable: true)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.remaining, 19, accuracy: 0.0001)
    }

    func testLockAfterTimingGapKeepsClockFrozenUntilUnlock() {
        var engine = running([20])
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        _ = engine.tick(elapsed: 9, screenAvailable: true)
        XCTAssertTrue(engine.isPaused)
        _ = engine.tick(elapsed: 2, screenAvailable: false)
        _ = engine.tick(elapsed: 2, screenAvailable: false)
        XCTAssertTrue(engine.isPaused, "a locked screen must keep the clock frozen after a timing gap")
        XCTAssertEqual(engine.remaining, 19, accuracy: 0.0001)
        _ = engine.tick(elapsed: 2, screenAvailable: true)
        XCTAssertFalse(engine.isPaused, "unlock ends the automatic pause")
        XCTAssertEqual(engine.remaining, 17, accuracy: 0.0001)
    }

    func testPausedStepNearCompletionDoesNotFinish() {
        var engine = running([2])
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        engine.pause()
        XCTAssertTrue(engine.tick(elapsed: 5, screenAvailable: true).isEmpty)
        XCTAssertFalse(engine.isFinished)
        engine.resume()
        XCTAssertEqual(engine.tick(elapsed: 1, screenAvailable: true), [.stepCompleted(.eyes), .allStepsCompleted])
    }

    func testCancelDropsCurrentStepWithoutRecordingIt() {
        var engine = running([20, 30])
        _ = engine.tick(elapsed: 5, screenAvailable: true)
        engine.cancel()
        XCTAssertFalse(engine.isActive)
        XCTAssertFalse(engine.isFinished)
        XCTAssertTrue(engine.tick(elapsed: 1, screenAvailable: true).isEmpty)
    }

    func testStartResetsFinishedStateForNewGroup() {
        var engine = running([20])
        _ = drain(&engine)
        XCTAssertTrue(engine.isFinished)
        engine.start([item(.stand, 300)])
        XCTAssertTrue(engine.isActive)
        XCTAssertFalse(engine.isFinished)
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(engine.remaining, 300, accuracy: 0.0001)
    }

    func testZeroElapsedTicksKeepClockAndBoundaryThreeIsCounted() {
        var engine = running([20])
        XCTAssertTrue(engine.tick(elapsed: 0, screenAvailable: true).isEmpty)
        XCTAssertEqual(engine.remaining, 20, accuracy: 0.0001)
        _ = engine.tick(elapsed: 3, screenAvailable: true)
        XCTAssertEqual(engine.remaining, 17, accuracy: 0.0001)
    }

    func testNegativeElapsedIsTreatedAsUntrustedGap() {
        var engine = running([20])
        _ = engine.tick(elapsed: -1, screenAvailable: true)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.remaining, 20, accuracy: 0.0001)
        _ = engine.tick(elapsed: 1, screenAvailable: true)
        XCTAssertFalse(engine.isPaused, "the gap clears on the next steady tick")
        XCTAssertEqual(engine.remaining, 19, accuracy: 0.0001)
    }

    func testFinalStepOvershootCompletesGroupInOneTick() {
        var engine = running([20])
        for _ in 0..<6 { _ = engine.tick(elapsed: 3, screenAvailable: true) }
        XCTAssertEqual(engine.remaining, 2, accuracy: 0.0001)
        XCTAssertEqual(engine.tick(elapsed: 3, screenAvailable: true),
                       [.stepCompleted(.eyes), .allStepsCompleted])
        XCTAssertTrue(engine.isFinished)
    }

    func testEmptyGroupIsInactiveAndEmitsNothing() {
        var engine = SessionEngine()
        engine.start([])
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(engine.tick(elapsed: 1, screenAvailable: true).isEmpty)
        XCTAssertNil(engine.currentItem)
    }
}
