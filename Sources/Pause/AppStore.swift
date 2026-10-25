import AppKit
import SwiftUI
import Combine
import PauseCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor final class AppStore: ObservableObject {
    @Published var preferences: Preferences {
        didSet {
            if oldValue.cloudEndpoint != preferences.cloudEndpoint || oldValue.cloudModel != preferences.cloudModel { preferences.cloudEnabled = false }
            preferencesChanged()
        }
    }
    @Published var days: [DayRecord]
    @Published var signal = Signal()
    @Published var decision = Decision(.wait, "欢迎，先了解这款应用如何工作")
    @Published var error: String?
    @Published var cloudStatus = "云端关闭 · 所有判断在本机完成"
    @Published var keyboardAvailable = false
    @Published var hasConsented: Bool
    @Published var session: [RoutineItem] = []
    @Published var sessionIndex = 0
    @Published var sessionRemaining = 0.0
    @Published var sessionPaused = false
    @Published var sessionFinished = false
    @Published var reminder: Decision?
    @Published var loginStatus = SMAppService.mainApp.status
    var showMainWindow: (() -> Void)?
    private var engine = DecisionEngine()
    private let sensors = Sensors()
    private var timer: Timer?
    private var lastSample = ProcessInfo.processInfo.systemUptime
    private var lastSessionTick = ProcessInfo.processInfo.systemUptime
    private var lastSave = ProcessInfo.processInfo.systemUptime
    private var cloudTask: Task<Void, Never>?
    private var cloudDeferred = false
    private var revision = UUID()
    private var panel: NSPanel?
    private let fileURL: URL
    private var storageWritable = true
    private var todayIndex: Int { days.firstIndex(where: { $0.dayID == DayRecord(date: Date()).dayID }) ?? days.count - 1 }
    private var monotonicNow: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var today: DayRecord { days[todayIndex] }
    var sessionActive: Bool { !session.isEmpty && sessionIndex < session.count }
    var currentItem: RoutineItem? { sessionActive ? session[sessionIndex] : nil }
    var enabledRoutine: [RoutineItem] { preferences.routine.filter(\.enabled) }
    var todayCompletions: Int { today.completed.values.reduce(0, +) }
    var weeklyDays: [DayRecord] {
        let calendar = Calendar.current
        return (0..<7).reversed().map { offset in
            let date = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: Date())!)
            return days.first(where: { $0.date == date }) ?? DayRecord(date: date)
        }
    }

    init() {
        fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Interval/state.json")
        var state = Archive()
        var loadError: String?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { state = try Archive.load(from: fileURL) }
            catch { loadError = "本地记录无法读取，已停止写入以保留原文件。请先备份原文件，再使用清除数据重新开始。\n\(error.localizedDescription)" }
        }
        state.preferences.normalize(); state.rollover(at: Date())
        preferences = state.preferences; days = state.days
        hasConsented = UserDefaults.standard.bool(forKey: "localConsent")
        if !hasConsented { preferences.monitoring = false }
        error = loadError; storageWritable = loadError == nil
        if preferences.monitoring && preferences.keyboardEnabled { sensors.startKeyboard(request: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer?.tolerance = 0.2
    }
    func consentAndStart() {
        hasConsented = true; UserDefaults.standard.set(true, forKey: "localConsent")
        preferences.monitoring = true
    }
    private func preferencesChanged() {
        revision = UUID(); cloudTask?.cancel(); cloudTask = nil
        if preferences.monitoring && preferences.keyboardEnabled { sensors.startKeyboard(request: false) }
        else { sensors.stopKeyboard() }
        keyboardAvailable = sensors.keyboardAvailable
        dismissReminder(snooze: false)
        if !preferences.cloudEnabled { cloudStatus = "云端关闭 · 所有判断在本机完成" }
        save()
    }
    func requestKeyboard() {
        preferences.keyboardEnabled = true
        if preferences.monitoring { sensors.startKeyboard(request: true) }
        keyboardAvailable = sensors.keyboardAvailable
    }
    private func rollover() {
        var archive = Archive(); archive.days = days; archive.rollover(at: Date()); days = archive.days
    }
    private func sample(now: Date) {
        let uptime = monotonicNow
        let seconds = uptime - lastSample; lastSample = uptime
        if preferences.monitoring {
            if preferences.keyboardEnabled { sensors.startKeyboard(request: false) }
            let (newSignal, keys) = sensors.read(preferences: preferences)
            signal = newSignal; keyboardAvailable = sensors.keyboardAvailable
            if !sessionActive {
                let active = engine.advance(seconds: seconds, signal: newSignal)
                days[todayIndex].screenSeconds += active
                days[todayIndex].keyCount += keys
            }
        } else {
            sensors.stopKeyboard(); signal = Signal(); keyboardAvailable = false
        }
        decision = engine.decide(now: monotonicNow, hour: Calendar.current.component(.hour, from: now), preferences: preferences, signal: signal, day: today)
    }
    private func tick() {
        let now = Date(); rollover()
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsed = uptime - lastSessionTick; lastSessionTick = uptime
        if uptime - lastSample >= 5 { sample(now: now) }
        if sessionActive && !sensors.screenAvailable { sessionPaused = true }
        if sessionActive && !sessionPaused {
            if elapsed >= 0 && elapsed <= 3 { sessionRemaining = max(0, sessionRemaining - elapsed) }
            else { sessionPaused = true }
            if sessionRemaining <= 0 { finishStep() }
        }
        decision = engine.decide(now: monotonicNow, hour: Calendar.current.component(.hour, from: now), preferences: preferences, signal: signal, day: today)
        if reminder != nil {
            // Mouse movement toward the invitation must not retract it; only protection does.
            let blocked = engine.blockingReason(now: monotonicNow, hour: Calendar.current.component(.hour, from: now), preferences: preferences, signal: signal) != nil
            let refocusEnded = reminder?.kind == .refocus && (preferences.context != .study || signal.category != .distracting || !preferences.distractionHints)
            if blocked || refocusEnded { dismissReminder(snooze: false) }
        }
        if !sessionActive && reminder == nil && cloudTask == nil {
            if case .rest(let activity) = decision.kind {
                if preferences.cloudEnabled && !cloudDeferred { consultCloud(activity: activity) }
                else { offer(decision) }
            } else if decision.kind == .refocus { offer(decision) }
        }
        if uptime - lastSave >= 30 { save() }
    }
    private func consultCloud(activity: Activity) {
        let token = revision; let p = preferences; let s = signal
        cloudStatus = "正在询问云端时机建议…"
        cloudTask = Task { [weak self] in
            guard let self else { return }
            var deferBreak = false
            do {
                let advice = try await CloudAdvisor.ask(preferences: p, signal: s, screenMinutes: Int(engine.continuousScreen / 60), activity: activity)
                deferBreak = advice.action == "defer"
                guard !Task.isCancelled, token == revision else { return }
                cloudStatus = deferBreak ? "云端建议稍后 · 最多延后 5 分钟一次" : "云端建议现在可以休息"
            } catch {
                guard !Task.isCancelled, token == revision else { return }
                cloudStatus = "云端不可用，已回退本地：\(error.localizedDescription)"
            }
            guard !Task.isCancelled, token == revision else { return }
            cloudTask = nil
            sample(now: Date())
            guard !sessionActive, reminder == nil, case .rest = decision.kind else { return }
            if deferBreak {
                engine.snoozeUntil = monotonicNow + 300; cloudDeferred = true
                decision = .init(.wait, "云端建议延后 5 分钟，本地保护仍然生效")
            } else { offer(decision) }
        }
    }
    private func offer(_ value: Decision) {
        reminder = value; engine.offered(value, at: monotonicNow); days[todayIndex].reminders += 1
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 200), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ReminderView(store: self))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 374, y: f.maxY - 224))
        }
        panel.orderFrontRegardless(); self.panel = panel
    }
    func dismissReminder(snooze: Bool = true) {
        panel?.orderOut(nil); panel = nil; reminder = nil
        if snooze { engine.snoozeUntil = monotonicNow + 300 }
    }
    func acceptReminder() {
        let value = reminder
        dismissReminder(snooze: false)
        if case .rest(let activity) = value?.kind { startSession(activities: [activity]) }
        else { engine.snoozeUntil = monotonicNow + 300 }
    }
    func snooze(minutes: Int) {
        engine.snoozeUntil = monotonicNow + Double(minutes * 60)
        dismissReminder(snooze: false); decision = .init(.wait, "已暂停提醒 \(minutes) 分钟")
    }
    func resumeReminders() { engine.snoozeUntil = -.greatestFiniteMagnitude; sample(now: Date()) }
    func startSession(activities: [Activity]? = nil) {
        dismissReminder(snooze: false); cloudTask?.cancel(); cloudTask = nil; revision = UUID()
        session = activities.map { selected in selected.compactMap { a in preferences.routine.first(where: { $0.activity == a }) } } ?? enabledRoutine
        sessionIndex = 0; sessionRemaining = Double(session.first?.durationSeconds ?? 0)
        sessionPaused = false; sessionFinished = false; lastSessionTick = ProcessInfo.processInfo.systemUptime
        showMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openIntervalWindow, object: nil)
    }
    private func finishStep() {
        guard let item = currentItem else { return }
        days[todayIndex].completed[item.activity.rawValue, default: 0] += 1
        engine.complete(item.activity); cloudDeferred = false
        if preferences.completionSound { NSSound(named: NSSound.Name("Tink"))?.play() }
        sessionIndex += 1
        if sessionActive { sessionRemaining = Double(session[sessionIndex].durationSeconds) }
        else { sessionFinished = true; engine.snoozeUntil = monotonicNow + 180 }
        save()
    }
    func cancelSession() { session = []; sessionFinished = false; engine.snoozeUntil = monotonicNow + 180 }
    func save() {
        guard storageWritable else { return }
        var archive = Archive(); archive.preferences = preferences; archive.days = days
        do { try archive.save(to: fileURL); lastSave = monotonicNow }
        catch { self.error = "本地保存失败：\(error.localizedDescription)" }
    }
    func exportData() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Interval-local-data.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var archive = Archive(); archive.preferences = preferences; archive.days = days
        do { try JSONEncoder().encode(archive).write(to: url, options: .atomic) }
        catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
    func eraseData() {
        cloudTask?.cancel(); cloudTask = nil; preferences = Preferences(); engine = DecisionEngine()
        cancelSession(); sensors.stopKeyboard()
        do {
            try APIKey.delete()
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            hasConsented = false; UserDefaults.standard.removeObject(forKey: "localConsent")
            days = [DayRecord(date: Calendar.current.startOfDay(for: Date()))]
            storageWritable = true; error = nil; save()
        } catch { self.error = "清除未完成：\(error.localizedDescription)" }
    }
    func setLogin(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
        } catch { self.error = "登录启动设置失败：\(error.localizedDescription)" }
    }
    func addFrontAppRule(_ category: AppCategory) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier }), let id = app.bundleIdentifier else { return }
        preferences.appRules.removeAll { $0.bundleID == id }
        preferences.appRules.append(AppRule(bundleID: id, category: category))
    }
}
extension Notification.Name { static let openIntervalWindow = Notification.Name("openIntervalWindow") }
