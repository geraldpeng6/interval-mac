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
            // The soundscape engine always mirrors the stored preference so any
            // write path (picker, eraseData reset, restore) stays in sync.
            if oldValue.soundscape != preferences.soundscape { sounds.selection = Soundscape.from(preferences.soundscape) }
            // Explicit monitoring-off must reset context dwell now, not at the next
            // sample (a <5 s pause/resume inside a sample period would carry it over).
            // A keyboard-only opt-out keeps the context: preferencesChanged's stopKeyboard.
            if oldValue.monitoring && !preferences.monitoring { sensors.stopMonitoring() }
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
    /// Built-in soundscape playback; follows the guided session automatically.
    let sounds = SoundEngine()
    var showMainWindow: (() -> Void)?
    private var engine = DecisionEngine()
    private var sessionEngine = SessionEngine()
    private let sensors = Sensors()
    private var timer: Timer?
    private var lastSample = ProcessInfo.processInfo.systemUptime
    private var lastSessionTick = ProcessInfo.processInfo.systemUptime
    private var lastSave = ProcessInfo.processInfo.systemUptime
    private var cloudTask: Task<Void, Never>?
    private var cloudDeferred = false
    private var revision = UUID()
    private var panel: NSPanel?
    /// Floating guide window shown while a session runs (nil when hidden).
    private var sessionWindow: SessionPanelController?
    private let fileURL: URL
    private var storageWritable = true
    private var todayIndex: Int { days.firstIndex(where: { $0.dayID == DayRecord(date: Date()).dayID }) ?? days.count - 1 }
    private var monotonicNow: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var today: DayRecord { days[todayIndex] }
    var sessionActive: Bool { sessionEngine.isActive }
    var currentItem: RoutineItem? { sessionEngine.currentItem }
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
        sounds.selection = Soundscape.from(state.preferences.soundscape)
        hasConsented = UserDefaults.standard.bool(forKey: "localConsent")
        if !hasConsented { preferences.monitoring = false }
        error = loadError; storageWritable = loadError == nil
        if preferences.monitoring && preferences.keyboardEnabled { sensors.startKeyboard(request: false) }
        // Unscheduled + added to .common so ticks keep firing during menu tracking and modal panels
        // (scheduledTimer only uses .default, which stalls there and leaves a discarded elapsed gap).
        let tickTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        tickTimer.tolerance = 0.2
        RunLoop.main.add(tickTimer, forMode: .common)
        timer = tickTimer
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
        // Non-tick callers (cloud continuation, resumeReminders) can run right after midnight
        // before the first tick; ensure today's bucket exists before any todayIndex write.
        rollover()
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
            sensors.stopMonitoring(); signal = Signal(); keyboardAvailable = false
        }
        decision = engine.decide(now: monotonicNow, hour: Calendar.current.component(.hour, from: now), preferences: preferences, signal: signal, day: today)
    }
    private func tick() {
        let now = Date(); rollover()
        let uptime = monotonicNow
        let elapsed = uptime - lastSessionTick; lastSessionTick = uptime
        if uptime - lastSample >= 5 { sample(now: now) }
        if sessionEngine.isActive {
            let events = sessionEngine.tick(elapsed: elapsed, screenAvailable: sensors.screenAvailable)
            var completed: [Activity] = []
            var finishedAll = false
            for event in events {
                if case .stepCompleted(let activity) = event { completed.append(activity) }
                if case .allStepsCompleted = event { finishedAll = true }
            }
            for activity in completed {
                days[todayIndex].completed[activity.rawValue, default: 0] += 1
                engine.complete(activity); cloudDeferred = false
            }
            if !completed.isEmpty && preferences.completionSound { NSSound(named: NSSound.Name("Tink"))?.play() }
            if finishedAll { engine.snoozeUntil = monotonicNow + 180 }
            if !events.isEmpty { save() }
            syncSession()
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
        guard !sessionEngine.isActive else { openMainWindow(); return }
        dismissReminder(snooze: false); cloudTask?.cancel(); cloudTask = nil; revision = UUID()
        let items = activities.map { selected in selected.compactMap { a in preferences.routine.first(where: { $0.activity == a }) } } ?? enabledRoutine
        sessionEngine.start(items)
        lastSessionTick = monotonicNow
        syncSession()
        showSessionGuide()
        openMainWindow()
    }
    func revealSession() { openMainWindow() }
    func toggleSessionPause() {
        // Resuming must not inherit time stalled since the last tick (e.g. the process napped while paused).
        if sessionEngine.isPaused { sessionEngine.resume(); lastSessionTick = monotonicNow }
        else if sessionEngine.isActive { sessionEngine.pause() }
        syncSession()
    }
    func cancelSession() {
        sessionEngine.cancel()
        syncSession()
        hideSessionGuide()
        engine.snoozeUntil = monotonicNow + 180
    }
    private func openMainWindow() {
        showMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openIntervalWindow, object: nil)
    }
    /// Every mutation of sessionEngine must be followed by this mirror write:
    /// the published session fields are the only thing views observe.
    private func syncSession() {
        session = sessionEngine.items
        sessionIndex = sessionEngine.index
        sessionRemaining = sessionEngine.remaining
        sessionPaused = sessionEngine.isPaused
        sessionFinished = sessionEngine.isFinished
        // The soundscape follows the guided session: plays while a step runs,
        // ducks when paused, and fades out when the group ends or is cancelled.
        sounds.sessionActive = sessionEngine.isActive
        sounds.sessionPaused = sessionEngine.isPaused
        sessionWindow?.sync(store: self)
    }
    func save() {
        guard storageWritable else { return }
        var archive = Archive(); archive.preferences = preferences; archive.days = days
        do { try archive.save(to: fileURL); lastSave = monotonicNow }
        catch { self.error = "本地保存失败：\(error.localizedDescription)" }
    }

    /// Shows the floating activity guide (idempotent); used by every session start.
    func showSessionGuide() {
        if sessionWindow == nil { sessionWindow = SessionPanelController() }
        sessionWindow?.show(store: self)
    }
    func hideSessionGuide() {
        sessionWindow?.hide()
        sessionWindow = nil
    }
    func exportData() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Interval-local-data.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var archive = Archive(); archive.preferences = preferences; archive.days = days
        do { try JSONEncoder().encode(archive).write(to: url, options: .atomic) }
        catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
    func eraseData() {
        // Honor the stop intent at once, but persist nothing until every fallible delete succeeded:
        // resetting preferences early would save defaults over the user's real state on failure.
        if cloudTask != nil { cloudStatus = "云端咨询已取消" }
        cloudTask?.cancel(); cloudTask = nil
        do {
            try APIKey.delete()
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            // Deletions succeeded — reset state. Days go first: the preferences didSet saves,
            // and it must not rewrite the old history over the just-deleted file.
            days = [DayRecord(date: Calendar.current.startOfDay(for: Date()))]
            storageWritable = true
            preferences = Preferences()
            engine = DecisionEngine()
            cancelSession()
            sensors.stopKeyboard()
            hasConsented = false; UserDefaults.standard.removeObject(forKey: "localConsent")
            error = nil; save()
        } catch {
            // Key and file deletes are separate steps; one may have succeeded. No atomic rollback exists.
            self.error = "清除未完成：\(error.localizedDescription)\n已保留你的偏好与统计，监测与提醒设置未变；若钥匙串 Key 已删除不会自动恢复，可重试清除。"
        }
    }
    func setLogin(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
        } catch { self.error = "登录启动设置失败：\(error.localizedDescription)" }
    }

    /// Persists the soundscape selection. The engine mirror lives in the
    /// preferences didSet, so every write path stays in sync.
    func setSoundscape(_ pref: SoundscapePref) {
        preferences.soundscape = pref
    }
    func addFrontAppRule(_ category: AppCategory) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier }), let id = app.bundleIdentifier else { return }
        preferences.appRules.removeAll { $0.bundleID == id }
        preferences.appRules.append(AppRule(bundleID: id, category: category))
    }
}
extension Notification.Name { static let openIntervalWindow = Notification.Name("openIntervalWindow") }
