import Foundation
import PauseCore

/// Drives one in-flight activity group: current step, remaining guided time, and why the clock is stopped.
/// AppStore supplies measured elapsed seconds and screen availability; this type owns the bookkeeping.
/// A pause the user asked for outlives screen loss and timer gaps; automatic pauses clear on their own.
struct SessionEngine: Equatable {
    enum PauseReason: Equatable { case user, screenUnavailable, timingGap }
    enum Event: Equatable { case stepCompleted(Activity); case allStepsCompleted }

    private(set) var items: [RoutineItem] = []
    private(set) var index: Int = 0
    private(set) var remaining: TimeInterval = 0
    private(set) var pauseReason: PauseReason?
    private(set) var isFinished = false

    var isActive: Bool { !items.isEmpty && index < items.count }
    var currentItem: RoutineItem? { isActive ? items[index] : nil }
    var isPaused: Bool { pauseReason != nil }

    mutating func start(_ newItems: [RoutineItem]) {
        items = newItems
        index = 0
        remaining = TimeInterval(newItems.first?.durationSeconds ?? 0)
        pauseReason = nil
        isFinished = false
    }

    mutating func cancel() {
        items = []
        index = 0
        remaining = 0
        pauseReason = nil
        isFinished = false
    }

    mutating func pause() {
        guard isActive else { return }
        pauseReason = .user
    }

    mutating func resume() { pauseReason = nil }

    mutating func tick(elapsed: TimeInterval, screenAvailable: Bool) -> [Event] {
        guard isActive else { return [] }
        // Priority: a pause the user asked for outlives everything; a lock supersedes a timing gap;
        // automatic pauses (lock, gap) clear on their own once the screen is back and the clock steady.
        if !screenAvailable {
            if pauseReason != .user { pauseReason = .screenUnavailable }
        } else if pauseReason != .user {
            pauseReason = nil
        }
        guard !isPaused else { return [] }
        guard elapsed >= 0, elapsed <= 3 else { pauseReason = .timingGap; return [] }
        remaining = max(0, remaining - elapsed)
        if remaining > 0 { return [] }
        var events: [Event] = [.stepCompleted(items[index].activity)]
        index += 1
        if index < items.count {
            remaining = TimeInterval(items[index].durationSeconds)
        } else {
            remaining = 0
            isFinished = true
            events.append(.allStepsCompleted)
        }
        return events
    }
}
