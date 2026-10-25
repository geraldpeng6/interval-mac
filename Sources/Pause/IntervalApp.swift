import SwiftUI
import AppKit

@main struct IntervalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("间歇 · Interval", id: "main") {
            RootView(store: store)
                .frame(minWidth: 860, minHeight: 650)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1020, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("开始一组活动") { store.startSession() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button(store.preferences.monitoring ? "暂停监测" : "继续监测") {
                    if store.hasConsented { store.preferences.monitoring.toggle() }
                }
            }
        }
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Label("间歇", systemImage: store.preferences.monitoring ? "leaf" : "pause.circle")
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { store?.save() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store?.showMainWindow?(); return true
    }
}
struct MenuContent: View {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text("间歇 · 今天已完成 \(store.todayCompletions) 次活动")
        Text(store.decision.reason)
        Divider()
        Button("打开间歇") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("开始一组活动") { store.startSession(); openWindow(id: "main") }.disabled(store.enabledRoutine.isEmpty)
        Menu("使用情境") {
            ForEach(PauseCore.Context.allCases) { context in
                Button((store.preferences.context == context ? "✓ " : "") + context.title) { store.preferences.context = context }
            }
        }
        Button("稍后 15 分钟提醒") { store.snooze(minutes: 15) }
        Button("恢复提醒") { store.resumeReminders() }
        if store.hasConsented {
            Button(store.preferences.monitoring ? "暂停监测" : "继续监测") { store.preferences.monitoring.toggle() }
        }
        Divider()
        Button("退出间歇") { store.save(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
import PauseCore
