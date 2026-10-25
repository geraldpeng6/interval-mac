import Foundation

public struct Archive: Codable, Sendable {
    public var version = 1
    public var preferences = Preferences()
    public var days: [DayRecord] = []
    public init() {}
    public mutating func rollover(at now: Date, calendar: Calendar = .current) {
        let record = DayRecord(date: now, calendar: calendar)
        if !days.contains(where: { $0.dayID == record.dayID }) { days.append(record) }
        let cutoff = DayRecord(date: calendar.date(byAdding: .day, value: -29, to: now)!, calendar: calendar).dayID
        // Preserve newer-labelled records when travel or a clock correction moves today's date back.
        days = days.filter { $0.dayID >= cutoff }.sorted { $0.dayID < $1.dayID }
    }
    public static func load(from url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    public func save(to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
