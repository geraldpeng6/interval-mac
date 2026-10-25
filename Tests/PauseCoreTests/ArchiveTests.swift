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
