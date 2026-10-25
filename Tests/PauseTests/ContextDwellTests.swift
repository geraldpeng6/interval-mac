import XCTest
@testable import Pause
import PauseCore

/// Behavior contracts for the context dwell producer behind `Sensors.read`:
/// sustained same-category seconds only accrue while observation is continuous.
/// The 90 s refocus gate in DecisionEngine trusts this number; these tests pin
/// the producer lifecycle it depends on.
final class ContextDwellTests: XCTestCase {
    /// Production sampling cadence: AppStore.tick samples at least every 5 s.
    private func dwell() -> ContextDwell { ContextDwell() }

    func testContinuousSameCategoryProgressesMonotonically() {
        var d = dwell()
        var seconds: TimeInterval = 0
        for t in stride(from: 5.0, through: 95.0, by: 5) {
            seconds = d.update(category: .distracting, now: t, screenAvailable: true)
        }
        XCTAssertEqual(seconds, 90, accuracy: 0.0001, "first observation starts the clock at 0; 90 monitored seconds need 18 accrual intervals")
    }

    func testCategoryChangeRestartsDwell() {
        var d = dwell()
        for t in stride(from: 5.0, through: 60.0, by: 5) {
            _ = d.update(category: .distracting, now: t, screenAvailable: true)
        }
        XCTAssertEqual(d.update(category: .neutral, now: 65, screenAvailable: true), 0, accuracy: 0.0001)
        XCTAssertEqual(d.update(category: .neutral, now: 70, screenAvailable: true), 5, accuracy: 0.0001)
        XCTAssertEqual(d.update(category: .distracting, now: 75, screenAvailable: true), 0, accuracy: 0.0001, "returning to the old category is a change too")
    }

    /// The explicit monitoring pause/resume path: AppStore calls Sensors.stopMonitoring,
    /// which resets the dwell; resumed monitoring starts from zero even in the same app.
    func testExplicitMonitoringStopResetsDwell() {
        var d = dwell()
        for t in stride(from: 5.0, through: 30.0, by: 5) {
            _ = d.update(category: .distracting, now: t, screenAvailable: true)
        }
        d.reset()
        XCTAssertEqual(d.update(category: .distracting, now: 155, screenAvailable: true), 0, accuracy: 0.0001, "paused wall-clock time must not count")
        XCTAssertEqual(d.update(category: .distracting, now: 160, screenAvailable: true), 5, accuracy: 0.0001)
    }

    /// Locked/unavailable screen: reads keep running on the timer, but dwell must not
    /// accrue behind the lock and must restart when the screen returns.
    func testUnavailableScreenPausesAndRestartsDwell() {
        var d = dwell()
        for t in stride(from: 5.0, through: 60.0, by: 5) {
            _ = d.update(category: .distracting, now: t, screenAvailable: true)
        }
        XCTAssertEqual(d.update(category: .distracting, now: 65, screenAvailable: false), 0, accuracy: 0.0001, "same category must not accrue while unavailable")
        XCTAssertEqual(d.update(category: .distracting, now: 180, screenAvailable: false), 0, accuracy: 0.0001)
        XCTAssertEqual(d.update(category: .distracting, now: 185, screenAvailable: true), 0, accuracy: 0.0001, "first returned available observation starts at 0, like a first observation; the unavailable period must not accrue")
    }

    /// A coalesced observation gap beyond the trusted maximum is a continuity break,
    /// not elapsed dwell; up to the trusted maximum it is steady cadence.
    func testObservationGapBeyondTrustedMaximumResetsDwell() {
        var d = dwell()
        XCTAssertEqual(d.update(category: .distracting, now: 0, screenAvailable: true), 0, accuracy: 0.0001)
        XCTAssertEqual(d.update(category: .distracting, now: 30, screenAvailable: true), 30, accuracy: 0.0001, "a gap at the trusted maximum still accrues")
        XCTAssertEqual(d.update(category: .distracting, now: 200, screenAvailable: true), 0, accuracy: 0.0001, "beyond it, dwell restarts")
        XCTAssertEqual(d.update(category: .distracting, now: 205, screenAvailable: true), 5, accuracy: 0.0001)
    }
}
