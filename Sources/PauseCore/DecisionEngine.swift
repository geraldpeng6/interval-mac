import Foundation

/// Small, interpretable on-device scoring model. No downloaded weights or content inspection.
public struct DecisionEngine: Sendable {
    public var screenSinceEyeRest: Double = 0
    public var continuousScreen: Double = 0
    public var exposure: [Activity: Double] = [:]
    public var recentTypingPeak: Double = 0
    public var snoozeUntil: TimeInterval = -.greatestFiniteMagnitude
    public var lastReminder: TimeInterval = -.greatestFiniteMagnitude
    public var lastRefocus: TimeInterval = -.greatestFiniteMagnitude
    public init() {}

    public mutating func advance(seconds: Double, signal: Signal) -> Double {
        guard seconds > 0, seconds <= 30 else { return 0 } // Sleep/wake is never counted as use.
        guard signal.screenAvailable else {
            continuousScreen = 0; screenSinceEyeRest = 0; return 0
        }
        recentTypingPeak = max(signal.keysPerMinute, recentTypingPeak * exp(-seconds / 300))
        if signal.idleSeconds >= 300 && signal.category != .media && !signal.fullscreen {
            continuousScreen = 0; screenSinceEyeRest = 0
            exposure = [:]
            return 0
        }
        // Reading/video is screen use too; presence cannot be inferred after prolonged inactivity.
        guard signal.idleSeconds < 120 || signal.category == .media || signal.fullscreen else { return 0 }
        continuousScreen += seconds; screenSinceEyeRest += seconds
        for a in Activity.allCases { exposure[a, default: 0] += seconds }
        return seconds
    }

    public func blockingReason(now: TimeInterval, hour: Int, preferences p: Preferences, signal s: Signal) -> String? {
        if !p.monitoring { return "监测已暂停" }
        if !s.screenAvailable { return "屏幕休眠或已锁定" }
        if now < snoozeUntil { return "稍后提醒，安心继续" }
        if p.isQuiet(hour: hour) { return "安静时段" }
        if p.context == .meeting || p.context == .movie { return "手动保护：\(p.context.title)" }
        if p.contextDetection {
            if s.category == .meeting { return "会议应用正在前台，暂不打扰" }
            if s.category == .media { return "影音应用正在前台，暂不打扰" }
            if p.protectMicrophone && s.microphoneBusy { return "麦克风正在使用，可能在通话" }
            if p.protectFullscreen && s.fullscreen { return "全屏使用中，暂不打扰" }
        }
        if s.idleSeconds >= 120 { return "已离开输入设备，等待返回" }
        return nil
    }

    public func decide(now: TimeInterval, hour: Int, preferences p: Preferences, signal s: Signal, day: DayRecord) -> Decision {
        if let reason = blockingReason(now: now, hour: hour, preferences: p, signal: s) { return .init(.wait, reason) }
        guard (now - lastReminder) >= 180 else { return .init(.wait, "刚刚提醒过，留一点空间") }
        if p.context == .study && p.contextDetection && p.distractionHints && s.category == .distracting && s.categorySeconds >= 90 && (now - lastRefocus) >= 1800 {
            return .init(.refocus, "学习模式下，在你标记的分心应用停留超过 90 秒")
        }
        let candidates = p.routine.filter(\.enabled).map { item -> (RoutineItem, Double) in
            let elapsed = item.activity == .eyes ? screenSinceEyeRest : exposure[item.activity, default: 0]
            let typingFactor = item.activity == .wrists && max(s.keysPerMinute, recentTypingPeak) >= Double(p.highTypingThreshold) ? 0.7 : 1.0
            let interval = Double(item.intervalMinutes) * 60 * typingFactor
            // A daily goal can bring a reminder forward, but never to less than 5 minutes.
            let remaining = max(0, item.dailyTarget - day.count(item.activity))
            let goalInterval = remaining > 0 ? max(300, (8 * 3600 - min(day.screenSeconds, 7 * 3600)) / Double(remaining)) : interval
            return (item, elapsed / min(interval, goalInterval))
        }.filter { $0.1 >= 1 }
        guard let candidate = candidates.max(by: { $0.1 < $1.1 }) else { return .init(.wait, "还不到休息的时候") }
        let gap = s.idleSeconds >= 8 && s.keysPerMinute < 60
        let score = min(1, max(0, 0.25 + (gap ? 0.6 : 0) + min(0.3, (candidate.1 - 1) * 0.2) - (s.keysPerMinute > 120 ? 0.25 : 0)))
        // After substantial delay, show a non-activating invitation; protected contexts always win.
        guard gap || candidate.1 >= 1.5 && s.keysPerMinute < 30 else {
            return .init(.wait, "\(candidate.0.activity.title)已到时间，等待输入间隙", score: score)
        }
        return .init(.rest(candidate.0.activity), gap ? "发现输入间隙，适合\(candidate.0.activity.title)" : "连续使用较久，邀请你短暂放松", score: score)
    }
    public mutating func complete(_ activity: Activity) {
        exposure[activity] = 0
        if activity == .eyes { screenSinceEyeRest = 0 }
        if activity == .stand { continuousScreen = 0 }
    }
    public mutating func offered(_ decision: Decision, at date: TimeInterval) {
        lastReminder = date
        if decision.kind == .refocus { lastRefocus = date }
    }
}

public enum Classifier {
    public static func category(bundleID: String, rules: [AppRule]) -> AppCategory {
        if let rule = rules.first(where: { $0.bundleID == bundleID }) { return rule.category }
        let id = bundleID.lowercased()
        if ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.facetime", "com.cisco.webexmeetingsapp"].contains(id) { return .meeting }
        if ["org.videolan.vlc", "com.colliderli.iina", "com.apple.tv", "com.apple.quicktimeplayerx"].contains(id) { return .media }
        if ["com.apple.dt.xcode", "com.microsoft.vscode", "com.apple.ibooksx", "com.apple.preview"].contains(id) { return .productive }
        return .neutral
    }
}
