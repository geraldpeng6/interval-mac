import SwiftUI
import Charts
import PauseCore

let intervalFill = Color(red: 0.23, green: 0.46, blue: 0.39)
let intervalAccent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.57, green: 0.80, blue: 0.69, alpha: 1)
        : NSColor(calibratedRed: 0.23, green: 0.46, blue: 0.39, alpha: 1)
})
enum Page: String, CaseIterable, Identifiable {
    case today = "今天", routine = "活动组合", insights = "使用趋势", settings = "偏好设置", privacy = "隐私与数据"
    var id: Self { self }
    var symbol: String {
        switch self { case .today: "sun.max"; case .routine: "figure.mind.and.body"; case .insights: "chart.bar.xaxis"; case .settings: "slider.horizontal.3"; case .privacy: "lock.shield" }
    }
}
struct RootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updates: UpdateEngine
    @State private var page: Page? = .today
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill").font(.system(size: 26)).foregroundStyle(intervalAccent)
                    VStack(alignment: .leading, spacing: 2) { Text("间歇").font(.title3.weight(.semibold)); Text("INTERVAL").font(.system(size: 9, weight: .medium, design: .rounded)).tracking(2).foregroundStyle(.secondary) }
                }.padding(.horizontal, 16).padding(.top, 20)
                List(Page.allCases, selection: $page) { item in Label(item.rawValue, systemImage: item.symbol).tag(item).padding(.vertical, 5) }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 6) {
                    Label("本地优先", systemImage: "lock.circle").font(.caption.weight(.medium))
                    Text("给专注留空间，\n给身体一点间歇。").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 230)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !store.hasConsented { WelcomeView(store: store) }
                    if store.sessionActive || store.sessionFinished { SessionView(store: store) }
                    switch page ?? .today {
                    case .today: TodayView(store: store)
                    case .routine: RoutineView(store: store)
                    case .insights: InsightsView(store: store)
                    case .settings: PreferencesView(store: store, updates: updates)
                    case .privacy: PrivacyView(store: store, updates: updates)
                    }
                }
                .padding(32)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Only the background color extends under the titlebar (covering the
            // resize seam); the content itself keeps the safe-area inset, so the
            // first heading is never covered. Putting .ignoresSafeArea on the
            // scroll view itself would slide content beneath the titlebar.
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea(edges: .top))
        }
        .tint(intervalAccent)
        // One continuous sidebar/detail divider: the two-column default draws two
        // abutting rounded backgrounds that leave a visible gap in the middle.
        .navigationSplitViewStyle(.balanced)
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: .all)
        .onAppear {
            let action = openWindow
            store.showMainWindow = { action(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }
        // Observed here rather than in the preferences surface so resets from
        // anywhere in the window (e.g. erasing all data) also reach the engine.
        .onChange(of: store.preferences.updateAutoCheck) { _, enabled in updates.setAutoCheck(enabled) }
        .onReceive(NotificationCenter.default.publisher(for: .openIntervalWindow)) { _ in openWindow(id: "main"); page = .today }
        .alert("需要留意", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}
struct Heading: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 29, weight: .semibold)); Text(subtitle).font(.callout).foregroundStyle(.secondary) } }
}
struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 10) { content }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1)) }
}
struct WelcomeView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Label("先照顾好你的隐私", systemImage: "hand.raised").font(.title3.weight(.semibold))
                Text("开启后，仅在本机估算亮屏使用时长、空闲间隙及前台应用类别。键盘计数单独授权；不读取输入文字、截图、网页地址或音频。默认不连接云端。")
                HStack { Button("同意并开启本地监测") { store.consentAndStart() }.buttonStyle(.borderedProminent).tint(intervalFill); Text("也可以先浏览和体验活动").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
struct TodayView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                Heading(title: "留一点空白。", subtitle: Date().formatted(.dateTime.month(.wide).day().weekday(.wide)) + " · 让休息发生在合适的时候")
                Spacer()
                Label(store.preferences.monitoring ? "正在轻轻守候" : "监测已暂停", systemImage: store.preferences.monitoring ? "circle.fill" : "pause.circle").font(.caption).foregroundStyle(intervalAccent).padding(10).background(intervalAccent.opacity(0.08), in: Capsule())
            }
            Surface {
                HStack(spacing: 24) {
                    ZStack {
                        Circle().stroke(intervalAccent.opacity(0.1), lineWidth: 9)
                        Circle().trim(from: 0, to: min(1, goalProgress)).stroke(intervalAccent, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 2) { Text("\(store.todayCompletions)").font(.system(size: 33, weight: .light, design: .rounded)); Text("次小小照顾").font(.caption).foregroundStyle(.secondary) }
                    }.frame(width: 126, height: 126).accessibilityLabel("今日完成 \(store.todayCompletions) 次活动")
                    VStack(alignment: .leading, spacing: 12) {
                        Text(store.decision.reason).font(.title3.weight(.medium))
                        Text("提醒会参考使用负荷、输入停顿与情境保护。\n现在想休息，也可以直接开始。").font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                        HStack {
                            Button("开始一组活动", systemImage: "play.fill") { store.startSession() }.buttonStyle(.borderedProminent).tint(intervalFill).disabled(store.enabledRoutine.isEmpty || store.sessionActive)
                            Button("稍后 15 分钟") { store.snooze(minutes: 15) }.buttonStyle(.bordered)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 14) {
                MetricView(title: "今日屏幕使用估算", value: duration(store.today.screenSeconds), symbol: "display")
                MetricView(title: "近一分钟按键", value: store.keyboardAvailable ? "\(Int(store.signal.keysPerMinute)) 次" : "未开启", symbol: "keyboard")
                MetricView(title: "今日温柔提醒", value: "\(store.today.reminders) 次", symbol: "leaf")
            }
            HStack { Text("今天的照顾计划").font(.title3.weight(.semibold)); Spacer(); Text("完成 / 每日目标").font(.caption).foregroundStyle(.secondary) }
            Surface {
                VStack(spacing: 16) {
                    ForEach(store.enabledRoutine) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.activity.symbol).font(.title3).foregroundStyle(intervalAccent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) { Text(item.activity.title).font(.body.weight(.medium)); Text(item.activity.subtitle).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text("\(store.today.count(item.activity)) / \(item.dailyTarget)").monospacedDigit().foregroundStyle(.secondary)
                            Button("开始") { store.startSession(activities: [item.activity]) }.disabled(store.sessionActive)
                        }
                        if item.id != store.enabledRoutine.last?.id { Divider() }
                    }
                    if store.enabledRoutine.isEmpty { Text("去活动组合开启你喜欢的活动。").foregroundStyle(.secondary) }
                }
            }
            Surface {
                HStack { Label("当前情境", systemImage: "sparkle"); Spacer(); Picker("当前情境", selection: $store.preferences.context) { ForEach(PauseCore.Context.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 190) }
                Text("自动判断是保守的场景估计，不读取你的工作内容。浏览器会议或观影可手动开启免打扰。").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }
    private var goalProgress: Double {
        let target = store.enabledRoutine.reduce(0) { $0 + $1.dailyTarget }
        let earned = store.enabledRoutine.reduce(0) { $0 + min($1.dailyTarget, store.today.count($1.activity)) }
        return target > 0 ? Double(earned) / Double(target) : 0
    }
}
struct MetricView: View {
    let title: String; let value: String; let symbol: String
    var body: some View { Surface { VStack(alignment: .leading, spacing: 10) { Image(systemName: symbol).foregroundStyle(intervalAccent); Text(value).font(.system(size: 24, weight: .medium, design: .rounded)); Text(title).font(.caption).foregroundStyle(.secondary) } } }
}
func duration(_ seconds: Double) -> String { let minutes = Int(seconds / 60); return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟" }

struct InsightsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Heading(title: "慢慢建立节奏。", subtitle: "只保留最近 30 天的本地每日汇总，没有活动内容记录。")
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                Text("最近七天 · 屏幕使用估算").font(.headline)
                Chart(store.weeklyDays) { day in
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value("小时", day.screenSeconds / 3600)).foregroundStyle(intervalAccent.gradient).cornerRadius(5)
                }.chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }.chartYAxisLabel("小时").frame(height: 210)
            }
        }
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Text("每一天的小进步").font(.headline)
                ForEach(store.weeklyDays.reversed()) { day in
                    HStack { Text(day.date.formatted(.dateTime.month().day())).frame(width: 85, alignment: .leading); Text(duration(day.screenSeconds)).foregroundStyle(.secondary); Spacer(); Text("\(day.keyCount) 次按键").foregroundStyle(.secondary); Text("\(day.completed.values.reduce(0, +)) 次活动").frame(width: 100, alignment: .trailing) }
                    if day.date != store.weeklyDays.first?.date { Divider() }
                }
            }
        }
        Text("估算依据：屏幕可用且近期有输入；前台影音或全屏会延长估算。它无法确认你是否真正注视屏幕，也不会自动认定你做了运动。").font(.caption).foregroundStyle(.secondary)
    }
}
