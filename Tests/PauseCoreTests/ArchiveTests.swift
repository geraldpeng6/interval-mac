import XCTest
@testable import PauseCore

final class ArchiveTests: XCTestCase {
    func testDailyRolloverRetentionAndAtomicRoundtrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var state = Archive()
        for offset in (0..<40).reversed() { state.rollover(at: calendar.date(byAdding: .day, value: -offset, to: now)!, calendar: calendar) }
        state.days[state.days.count - 1].completed["eyes"] = 3
        state.preferences.monitoring = true
        state.preferences.routine.swapAt(0, 2)
        try state.save(to: file)
        let restored = try Archive.load(from: file)
        XCTAssertEqual(restored.days.count, 30)
        XCTAssertEqual(restored.days.last?.count(.eyes), 3)
        XCTAssertTrue(restored.preferences.monitoring)
        XCTAssertEqual(restored.preferences.routine.first?.activity, .shoulders)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        state.rollover(at: now, calendar: calendar)
        XCTAssertEqual(state.days.count, 30)
    }
    func testOlderPreferencesKeepStatisticsAndDefaultNewOptionalSetting() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var archive = Archive(); archive.rollover(at: Date()); archive.days[0].completed["eyes"] = 3
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "completionSound"); json["preferences"] = preferences
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let restored = try Archive.load(from: file)
        XCTAssertTrue(restored.preferences.completionSound)
        XCTAssertEqual(restored.days[0].count(.eyes), 3)
    }
    func testUpdateAutoCheckRoundTripsAndOldArchivesDefaultToOn() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var archive = Archive(); archive.rollover(at: Date())
        archive.preferences.updateAutoCheck = false
        try archive.save(to: file)
        XCTAssertFalse(try Archive.load(from: file).preferences.updateAutoCheck)
        // An archive written before the updater existed enables automatic checks
        // (the documented default) without touching any other preference.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "updateAutoCheck"); json["preferences"] = preferences
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertTrue(try Archive.load(from: file).preferences.updateAutoCheck)
    }
    func testSoundscapePreferenceRoundTripsAndOldArchivesDefaultToOff() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var archive = Archive(); archive.rollover(at: Date())
        archive.preferences.soundscape = .rain
        try archive.save(to: file)
        XCTAssertEqual(try Archive.load(from: file).preferences.soundscape, .rain)
        // Archives written before soundscapes existed default to silent playback.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "soundscape"); json["preferences"] = preferences
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertEqual(try Archive.load(from: file).preferences.soundscape, .none)
    }
    func testSoundscapeMirrorEnumsStayAlignedWithPlaybackFiles() {
        // The UI/storage enum (PauseCore) and the playback enum (Pause) are two
        // hand-maintained mirrors; a case added to one side only would silently
        // fall back to silence. Raw values must map 1:1 and cover the packaged
        // sound files (see scripts/make-sounds.swift).
        let storage = SoundscapePref.allCases.map(\.rawValue).sorted()
        let playback = ["campfire", "evening-pad", "forest", "morning-birds", "none", "ocean-waves", "rain", "white-noise"]
        XCTAssertEqual(storage, playback)
    }
    func testTimeZoneChangePreservesDailyRecords() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var taipei = utc; taipei.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let instant = Date(timeIntervalSince1970: 1_792_929_600) // 2026-10-25 12:00 UTC
        var state = Archive(); state.rollover(at: instant, calendar: utc)
        state.days[0].screenSeconds = 3600; state.days[0].completed["eyes"] = 3
        state.rollover(at: instant, calendar: taipei)
        XCTAssertEqual(state.days.reduce(0) { $0 + $1.screenSeconds }, 3600)
        XCTAssertEqual(state.days.reduce(0) { $0 + $1.count(.eyes) }, 3)
        XCTAssertEqual(state.days.count, 1)
    }
    /// The fullscreen guide indexes per-step art and time shares with these two
    /// arrays via zip-style consumers; a length mismatch would silently drop
    /// steps, and non-positive weights would divide-by-zero the normalization.
    func testFullscreenStepArtArraysStayAlignedAndPositive() {
        for activity in Activity.allCases {
            XCTAssertEqual(activity.stepSymbols.count, activity.steps.count, "\(activity.rawValue) symbols")
            XCTAssertEqual(activity.stepWeights.count, activity.steps.count, "\(activity.rawValue) weights")
            XCTAssertTrue(activity.stepWeights.allSatisfy { $0 > 0 }, "\(activity.rawValue) weights must be positive")
            XCTAssertGreaterThan(activity.stepWeights.reduce(0, +), 0)
        }
    }
    /// Archives written before the fullscreen guide existed carry no per-step
    /// art — stepSymbols/stepWeights are derived properties, not stored fields,
    /// so the old JSON must keep loading with the arrays present and aligned.
    func testPreFullscreenArchiveKeepsDerivingStepArtArrays() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var archive = Archive(); archive.rollover(at: Date()); archive.days[0].completed["eyes"] = 2
        try archive.save(to: file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
        XCTAssertFalse(preferences.keys.contains { $0.lowercased().contains("step") },
                       "the per-step arrays must stay derived, never persisted")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let restored = try Archive.load(from: file)
        XCTAssertEqual(restored.days[0].count(.eyes), 2)
        for activity in Activity.allCases {
            XCTAssertEqual(restored.preferences.routine.first(where: { $0.activity == activity })?.activity.stepSymbols.count,
                           activity.steps.count, "\(activity.rawValue) symbols after restore")
        }
    }
    /// Normalized step durations for the default configured durations. Wrists
    /// uses absolute weights [1,1,1,1] — normalization (not raw multiplication)
    /// is what makes four 15-second steps out of 60 seconds; this pins the
    /// exact arithmetic the fullscreen captions display.
    func testNormalizedStepDurationsMatchDocumentedRhythm() {
        func shares(_ activity: Activity, _ duration: Int) -> [Double] {
            let total = activity.stepWeights.reduce(0, +)
            return activity.stepWeights.map { $0 / total * Double(duration) }
        }
        // XCTAssertEqual(_:accuracy:) has no array overload; zip per element.
        func assertClose(_ actual: [Double], _ expected: [Double], _ label: String) {
            XCTAssertEqual(actual.count, expected.count, label)
            for (a, e) in zip(actual, expected) {
                XCTAssertEqual(a, e, accuracy: 0.0001, label)
            }
        }
        assertClose(shares(.eyes, 20), [12, 8], "eyes 20s")
        assertClose(shares(.wrists, 60), [15, 15, 15, 15], "wrists 60s")
        assertClose(shares(.shoulders, 60), [15, 24, 21], "shoulders 60s")
        assertClose(shares(.stand, 300), [30, 225, 45], "stand 300s")
        assertClose(shares(.pelvic, 60), [12, 33, 15], "pelvic 60s")
    }
    func testCorruptArchiveFailsInsteadOfSilentlyOverwriting() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("not json".utf8); try original.write(to: file)
        XCTAssertThrowsError(try Archive.load(from: file))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testNormalizationPreservesUserOrderAndBoundsInvalidConfiguration() {
        var p = Preferences(); p.routine = [.init(.stand, interval: -4, duration: 0, target: 999)]
        p.normalize()
        XCTAssertEqual(p.routine.first?.activity, .stand)
        XCTAssertEqual(p.routine.first?.intervalMinutes, 5)
        XCTAssertEqual(p.routine.first?.durationSeconds, 60)
        XCTAssertEqual(p.routine.first?.dailyTarget, 30)
        XCTAssertEqual(Set(p.routine.map(\.activity)).count, 5)
    }
}
