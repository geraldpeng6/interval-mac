import Foundation

public enum Activity: String, Codable, CaseIterable, Identifiable, Sendable {
    case eyes, wrists, shoulders, stand, pelvic
    public var id: String { rawValue }
    public var title: String {
        switch self { case .eyes: "远眺护眼"; case .wrists: "手腕拉伸"; case .shoulders: "肩颈放松"; case .stand: "起身走动"; case .pelvic: "盆底觉察（提肛）" }
    }
    public var symbol: String {
        switch self { case .eyes: "eye"; case .wrists: "hand.raised.fingers.spread"; case .shoulders: "figure.flexibility"; case .stand: "figure.walk"; case .pelvic: "wind" }
    }
    public var subtitle: String {
        switch self { case .eyes: "看向约 6 米外，轻柔眨眼"; case .wrists: "轻柔舒展前臂，不追求幅度"; case .shoulders: "放低肩膀，缓慢转头"; case .stand: "离开座位，换一种姿势"; case .pelvic: "轻轻收缩，也充分放松" }
    }
    public var steps: [String] {
        switch self {
        case .eyes: ["看向约 6 米以外的真实物体，让视线离开这块屏幕。", "自然呼吸，轻柔、完整地眨眼。无需盯着倒计时。"]
        case .wrists: ["放下键盘，放松肩膀。若手腕当下疼痛、麻木或有损伤，跳过拉伸，先休息或咨询专业人员。", "左臂舒适地向前伸，掌心向下、手指朝地。右手轻扶左手，让前臂有轻微牵拉感，至少 15 秒；不弹震、不忍痛。", "缓慢松开，换右侧做同样的轻柔拉伸，至少 15 秒。自然呼吸，不追求更大的幅度。", "慢慢回到自然位置，张开五指，再轻轻放松。有疼痛或刺痛时立即结束，不要反复拉扯。"]
        case .shoulders: ["坐直，放低双肩，保持自然呼吸。", "缓慢向左转头，在舒适位置停留约 5 秒，再回正；换右侧。", "轻轻向后转动肩膀。不要绕颈一整圈，也不要强拉头部。"]
        case .stand: ["放下手上的工作，扶稳桌面后缓慢站起。", "在安全、平坦的位置轻松走动，或交替变换站姿。", "自然呼吸。无需长时间僵站；不便站立时可改为坐姿活动。"]
        case .pelvic: ["仅在适合你的情况下练习。坐稳、放松腹部，自然呼吸。", "轻轻向内向上提起盆底约 2 秒，然后完全放松至少 4 秒。按自己的节奏重复，不要憋气或夹紧臀部。", "重点感受充分放松。不要在排尿时训练；有盆底疼痛、紧绷或术后情况，先咨询专业人员。"]
        }
    }
    public var minimumDuration: Int {
        switch self { case .eyes: 20; case .wrists: 60; case .shoulders: 30; case .stand: 60; case .pelvic: 30 }
    }
    public var source: URL {
        switch self {
        case .eyes: URL(string: "https://www.aao.org/eye-health/tips-prevention/computer-usage")!
        case .wrists: URL(string: "https://www.mayoclinic.org/healthy-lifestyle/adult-health/multimedia/forearm-stretches/vid-20084698")!
        case .shoulders: URL(string: "https://www.nhs.uk/live-well/exercise/sitting-exercises/")!
        case .stand: URL(string: "https://www.hse.gov.uk/msd/dse/work-routine.htm")!
        case .pelvic: URL(string: "https://www.nhsinform.scot/healthy-living/womens-health/middle-years-around-25-to-50-years/pelvic-health/pelvic-floor-muscles/")!
        }
    }
    /// One symbol per guided step, for the fullscreen immersive guide. The
    /// fullscreen presentation stages each activity (breathe → focus → settle),
    /// so it needs finer-grained art than `symbol`. Callers require
    /// `stepSymbols.count == steps.count` (asserted in PauseCoreTests).
    public var stepSymbols: [String] {
        switch self {
        case .eyes: ["eye", "eye.fill"]
        case .wrists: ["hand.raised.fingers.spread", "hand.point.up.left", "hand.point.right", "hand.wave"]
        case .shoulders: ["figure.flexibility", "arrow.left.arrow.right", "arrow.triangle.2.circlepath"]
        case .stand: ["arrow.up.to.line", "figure.walk", "leaf"]
        case .pelvic: ["figure.mind.and.body", "wind", "leaf"]
        }
    }
    /// Relative share of the guided time each step takes. Raw values are
    /// intentional absolute weights, NOT proportions: consumers must divide by
    /// the sum (`weight / stepWeights.sum() × durationSeconds`). wrists uses
    /// [1,1,1,1] so four equal steps each get duration/4 — multiplying by the
    /// raw value instead would give each step the full duration. Guaranteed
    /// non-empty and all-positive so normalized shares are well defined.
    public var stepWeights: [Double] {
        switch self {
        case .eyes: [0.6, 0.4]
        case .wrists: [1, 1, 1, 1]
        case .shoulders: [0.25, 0.4, 0.35]
        case .stand: [0.1, 0.75, 0.15]
        case .pelvic: [0.2, 0.55, 0.25]
        }
    }
}

public struct RoutineItem: Codable, Identifiable, Equatable, Sendable {
    public var activity: Activity
    public var enabled: Bool
    public var intervalMinutes: Int
    public var durationSeconds: Int
    public var dailyTarget: Int
    public var id: Activity { activity }
    public init(_ activity: Activity, interval: Int, duration: Int, target: Int, enabled: Bool = true) {
        self.activity = activity; self.intervalMinutes = interval; self.durationSeconds = duration
        self.dailyTarget = target; self.enabled = enabled
    }
    public static let defaults: [Self] = [
        .init(.eyes, interval: 20, duration: 20, target: 8),
        .init(.wrists, interval: 50, duration: 60, target: 3),
        .init(.shoulders, interval: 50, duration: 60, target: 3),
        .init(.stand, interval: 60, duration: 300, target: 6),
        .init(.pelvic, interval: 120, duration: 60, target: 1, enabled: false)
    ]
}
public enum Context: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, work, study, meeting, movie
    public var id: String { rawValue }
    public var title: String {
        switch self { case .automatic: "智能判断"; case .work: "工作"; case .study: "学习"; case .meeting: "会议免打扰"; case .movie: "观影免打扰" }
    }
}
public enum AppCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case productive, distracting, meeting, media, neutral
    public var id: String { rawValue }
    public var title: String {
        switch self { case .productive: "工作 / 学习"; case .distracting: "容易分心"; case .meeting: "会议（保护）"; case .media: "影音（保护）"; case .neutral: "普通应用" }
    }
}
public struct AppRule: Codable, Identifiable, Sendable {
    public var bundleID: String
    public var category: AppCategory
    public var id: String { bundleID }
    public init(bundleID: String, category: AppCategory) { self.bundleID = bundleID; self.category = category }
}
/// Codable mirror of the UI-facing soundscape choices (PauseCore has no
/// AVFoundation dependency; the raw values match SoundEngine's file stems).
public enum SoundscapePref: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case whiteNoise = "white-noise"
    case rain
    case forest
    case eveningPad = "evening-pad"
    case campfire
    case oceanWaves = "ocean-waves"
    case morningBirds = "morning-birds"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "关闭"
        case .whiteNoise: "白噪声"
        case .rain: "雨声"
        case .forest: "林间"
        case .eveningPad: "暮色音乐"
        case .campfire: "篝火"
        case .oceanWaves: "海浪"
        case .morningBirds: "晨间鸟鸣"
        }
    }
}
public struct Preferences: Codable, Sendable {
    public var monitoring = false
    public var keyboardEnabled = false
    public var contextDetection = true
    public var protectFullscreen = true
    public var protectMicrophone = true
    public var distractionHints = true
    public var completionSound = true
    public var context: Context = .automatic
    public var highTypingThreshold = 180
    public var quietStart = 22
    public var quietEnd = 8
    public var quietHours = true
    public var routine = RoutineItem.defaults
    public var appRules: [AppRule] = []
    public var cloudEnabled = false
    public var cloudEndpoint = "https://api.openai.com/v1/chat/completions"
    public var cloudModel = ""
    /// App update checks against this repository's public GitHub Releases.
    /// Separate from the optional cloud advice: turning this off only stops the
    /// automatic update checks/downloads, never the health cloud toggle or key.
    public var updateAutoCheck = true
    /// Built-in soundscape played while a guided activity runs. Local playback
    /// only; `.none` keeps the app silent as before.
    public var soundscape = SoundscapePref.none
    public init() {}
    private enum CodingKeys: String, CodingKey { case monitoring, keyboardEnabled, contextDetection, protectFullscreen, protectMicrophone, distractionHints, completionSound, context, highTypingThreshold, quietStart, quietEnd, quietHours, routine, appRules, cloudEnabled, cloudEndpoint, cloudModel, updateAutoCheck, soundscape }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monitoring = try c.decodeIfPresent(Bool.self, forKey: .monitoring) ?? monitoring
        keyboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .keyboardEnabled) ?? keyboardEnabled
        contextDetection = try c.decodeIfPresent(Bool.self, forKey: .contextDetection) ?? contextDetection
        protectFullscreen = try c.decodeIfPresent(Bool.self, forKey: .protectFullscreen) ?? protectFullscreen
        protectMicrophone = try c.decodeIfPresent(Bool.self, forKey: .protectMicrophone) ?? protectMicrophone
        distractionHints = try c.decodeIfPresent(Bool.self, forKey: .distractionHints) ?? distractionHints
        completionSound = try c.decodeIfPresent(Bool.self, forKey: .completionSound) ?? completionSound
        context = try c.decodeIfPresent(Context.self, forKey: .context) ?? context
        highTypingThreshold = try c.decodeIfPresent(Int.self, forKey: .highTypingThreshold) ?? highTypingThreshold
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart) ?? quietStart
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd) ?? quietEnd
        quietHours = try c.decodeIfPresent(Bool.self, forKey: .quietHours) ?? quietHours
        routine = try c.decodeIfPresent([RoutineItem].self, forKey: .routine) ?? routine
        appRules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? appRules
        cloudEnabled = try c.decodeIfPresent(Bool.self, forKey: .cloudEnabled) ?? cloudEnabled
        cloudEndpoint = try c.decodeIfPresent(String.self, forKey: .cloudEndpoint) ?? cloudEndpoint
        cloudModel = try c.decodeIfPresent(String.self, forKey: .cloudModel) ?? cloudModel
        updateAutoCheck = try c.decodeIfPresent(Bool.self, forKey: .updateAutoCheck) ?? updateAutoCheck
        soundscape = try c.decodeIfPresent(SoundscapePref.self, forKey: .soundscape) ?? soundscape
    }
    public mutating func normalize() {
        highTypingThreshold = min(600, max(30, highTypingThreshold))
        quietStart = min(23, max(0, quietStart)); quietEnd = min(23, max(0, quietEnd))
        var seen = Set<Activity>()
        routine = routine.filter { seen.insert($0.activity).inserted }
        routine += RoutineItem.defaults.filter { !seen.contains($0.activity) }
        for i in routine.indices {
            routine[i].intervalMinutes = min(180, max(5, routine[i].intervalMinutes))
            routine[i].durationSeconds = min(600, max(routine[i].activity.minimumDuration, routine[i].durationSeconds))
            routine[i].dailyTarget = min(30, max(0, routine[i].dailyTarget))
        }
    }
    public func isQuiet(hour: Int) -> Bool {
        guard quietHours, quietStart != quietEnd else { return false }
        return quietStart < quietEnd ? (quietStart..<quietEnd).contains(hour) : hour >= quietStart || hour < quietEnd
    }
}
public struct DayRecord: Codable, Identifiable, Sendable {
    public var dayID: String
    public var date: Date {
        let parts = dayID.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .distantPast }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? .distantPast
    }
    public var screenSeconds: Double = 0
    public var keyCount = 0
    public var completed: [String: Int] = [:]
    public var reminders = 0
    public var id: String { dayID }
    public init(date: Date, calendar: Calendar = .current) { dayID = Self.key(for: date, calendar: calendar) }
    static func key(for date: Date, calendar input: Calendar) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    private enum CodingKeys: String, CodingKey { case dayID, date, screenSeconds, keyCount, completed, reminders }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let key = try c.decodeIfPresent(String.self, forKey: .dayID) { dayID = key }
        else { dayID = Self.key(for: try c.decode(Date.self, forKey: .date), calendar: .current) }
        screenSeconds = try c.decode(Double.self, forKey: .screenSeconds)
        keyCount = try c.decode(Int.self, forKey: .keyCount)
        completed = try c.decode([String: Int].self, forKey: .completed)
        reminders = try c.decode(Int.self, forKey: .reminders)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dayID, forKey: .dayID); try c.encode(screenSeconds, forKey: .screenSeconds)
        try c.encode(keyCount, forKey: .keyCount); try c.encode(completed, forKey: .completed); try c.encode(reminders, forKey: .reminders)
    }
    public func count(_ activity: Activity) -> Int { completed[activity.rawValue, default: 0] }
}
public struct Signal: Sendable {
    public var idleSeconds: Double = 0
    public var keysPerMinute: Double = 0
    public var category: AppCategory = .neutral
    public var fullscreen = false
    public var microphoneBusy = false
    public var screenAvailable = true
    public var categorySeconds: Double = 0
    public init() {}
}
public struct Decision: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case wait, rest(Activity), refocus }
    public var kind: Kind
    public var reason: String
    public var score: Double
    public init(_ kind: Kind, _ reason: String, score: Double = 0) { self.kind = kind; self.reason = reason; self.score = score }
}
