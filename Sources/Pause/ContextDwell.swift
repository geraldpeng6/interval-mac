import Foundation
import PauseCore

/// Owns sustained same-category dwell for context decisions (the `categorySeconds`
/// producer consumed by `Sensors.read`). Dwell only accrues while observation is
/// continuous: an explicit monitoring stop, an unavailable screen — including the
/// lock/screens-sleep notifications Sensors observes between samples — or a sampling
/// gap beyond the trusted maximum restarts it; otherwise it progresses while the
/// category is unchanged and restarts on a category change.
struct ContextDwell {
    /// Sampling runs at least every 5 s; DecisionEngine.advance trusts coalesced
    /// elapsed time only up to 30 s. The same bound separates a steady cadence
    /// from an observation gap here.
    static let trustedGap: TimeInterval = 30

    private(set) var category: AppCategory = .neutral
    private(set) var seconds: TimeInterval = 0
    private var lastUpdate: TimeInterval?

    /// Records one observation on the Sensors monotonic clock and returns the dwell seconds.
    /// An unavailable observation invalidates `lastUpdate` so the first available
    /// observation after it starts from 0, like a first observation.
    mutating func update(category newCategory: AppCategory, now: TimeInterval, screenAvailable: Bool) -> TimeInterval {
        let gap = lastUpdate.map { now - $0 } ?? 0
        lastUpdate = screenAvailable ? now : nil
        if newCategory != category || !screenAvailable || gap < 0 || gap > Self.trustedGap {
            category = newCategory
            seconds = 0
        } else {
            seconds += gap
        }
        return seconds
    }

    /// Monitoring stopped explicitly (not a keyboard opt-out) or the screen became
    /// unavailable between samples: nothing carries into the next period.
    /// Production callers: `Sensors.stopMonitoring` and the lock/screens-sleep observers.
    mutating func reset() {
        self = ContextDwell()
    }
}
