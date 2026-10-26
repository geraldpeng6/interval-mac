import SwiftUI
import AppKit

@main struct IntervalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: AppStore
    @StateObject private var updates: UpdateEngine
    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        let engine = UpdateEngine.production()
        // Wired at launch, not on window appearance: the app regularly runs as a
        // menu-bar-only process with no window, and both the install-time session
        // re-check and the automatic check schedule must not depend on one.
        engine.attach(sessionActive: { store.sessionActive })
        engine.setAutoCheck(store.preferences.updateAutoCheck)
        _updates = StateObject(wrappedValue: engine)
    }
    var body: some Scene {
        Window("间歇 · Interval", id: "main") {
            RootView(store: store, updates: updates)
                .frame(minWidth: 860, minHeight: 650)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1020, height: 740)
        .windowResizability(.contentMinSize)
        // The sidebar carries the brand; a title label in the toolbar would sit
        // on its own material patch next to the sidebar's titlebar segment.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(store.sessionActive ? "回到进行中的活动" : "开始一组活动") {
                    if store.sessionActive { store.revealSession() } else { store.startSession() }
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button(store.preferences.monitoring ? "暂停监测" : "继续监测") {
                    if store.hasConsented { store.preferences.monitoring.toggle() }
                }
            }
        }
        MenuBarExtra {
            MenuContent(store: store, updates: updates)
        } label: {
            Label {
                Text("间歇")
            } icon: {
                Image(systemName: sessionSymbol)
            }
            .accessibilityLabel(menuBarAccessibilityLabel)
        }
    }
    private var sessionSymbol: String {
        if store.sessionActive { return store.sessionPaused ? "pause.circle.fill" : "hourglass" }
        return store.preferences.monitoring ? "leaf" : "pause.circle"
    }
    private var menuBarAccessibilityLabel: String {
        if store.sessionActive, let item = store.currentItem {
            return store.sessionPaused ? "间歇，活动已暂停：\(item.activity.title)" : "间歇，正在活动：\(item.activity.title)"
        }
        return store.preferences.monitoring ? "间歇，监测中" : "间歇，监测已暂停"
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        store?.sounds.stop()
        store?.save()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store?.showMainWindow?(); return true
    }
}
struct MenuContent: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updates: UpdateEngine
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text("间歇 · 今天已完成 \(store.todayCompletions) 次活动")
        Text(store.decision.reason)
        Divider()
        if store.sessionActive, let item = store.currentItem {
            Text("进行中 · \(item.activity.title) · \(store.sessionPaused ? "已暂停" : sessionClock(store.sessionRemaining))")
            Button(store.sessionPaused ? "继续活动" : "暂停活动") { store.toggleSessionPause() }
            Button("结束这组活动") { store.cancelSession() }
            Button("打开活动窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
        } else if store.sessionFinished {
            Text("这组活动已完成")
            Button("知道了") { store.cancelSession() }
            Divider()
        }
        if !store.sessionActive { Button("打开间歇") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } }
        Button("开始一组活动") { store.startSession(); openWindow(id: "main") }
            .disabled(store.enabledRoutine.isEmpty || store.sessionActive)
        Menu("使用情境") {
            ForEach(PauseCore.Context.allCases) { context in
                Button((store.preferences.context == context ? "✓ " : "") + context.title) { store.preferences.context = context }
            }
        }
        Menu("活动音景") {
            ForEach(PauseCore.SoundscapePref.allCases) { pref in
                Button((store.preferences.soundscape == pref ? "✓ " : "") + pref.title) { store.setSoundscape(pref) }
            }
        }
        Button("稍后 15 分钟提醒") { store.snooze(minutes: 15) }
        Button("恢复提醒") { store.resumeReminders() }
        if store.hasConsented {
            Button(store.preferences.monitoring ? "暂停监测" : "继续监测") { store.preferences.monitoring.toggle() }
        }
        Divider()
        Text("当前版本 \(updates.currentVersionDisplay)")
        Text(updates.statusText)
        if let notice = updates.notice { Text(notice) }
        Button("检查更新") { updates.checkForUpdates() }.disabled(!updates.canCheck)
        if updates.isReady {
            Button("更新") { updates.updateButtonPressed() }.disabled(store.sessionActive)
            if store.sessionActive { Text("请先完成或结束当前活动") }
        }
        if updates.isFailed { Button("重试") { updates.checkForUpdates() } }
        Divider()
        Button("退出间歇") { store.save(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
import PauseCore
