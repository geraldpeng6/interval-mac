import SwiftUI
import PauseCore

struct RoutineView: View {
    @ObservedObject var store: AppStore
    @State private var expanded: Activity?
    @State private var reset = false
    var body: some View {
        Heading(title: "你的办公桌小仪式。", subtitle: "选择活动、调整频率和每日目标。组合依照下面的顺序进行。")
        ForEach($store.preferences.routine) { $item in
            Surface {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: item.activity.symbol).font(.title2).foregroundStyle(.tint).frame(width: 35)
                        VStack(alignment: .leading, spacing: 4) { Text(item.activity.title).font(.headline); Text(item.activity.subtitle).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { move(item.activity, by: -1) } label: { Image(systemName: "arrow.up") }.help("向前移").disabled(store.preferences.routine.first?.activity == item.activity)
                        Button { move(item.activity, by: 1) } label: { Image(systemName: "arrow.down") }.help("向后移").disabled(store.preferences.routine.last?.activity == item.activity)
                        Toggle("启用", isOn: $item.enabled).toggleStyle(.switch).labelsHidden().accessibilityLabel("启用\(item.activity.title)")
                    }
                    HStack(spacing: 24) {
                        Stepper("间隔 \(item.intervalMinutes) 分钟", value: $item.intervalMinutes, in: 5...180, step: 5)
                        Stepper("时长 \(item.durationSeconds) 秒", value: $item.durationSeconds, in: item.activity.minimumDuration...600, step: 10)
                        Stepper("每日 \(item.dailyTarget) 次", value: $item.dailyTarget, in: 0...30)
                    }.font(.callout).disabled(!item.enabled)
                    DisclosureGroup("动作说明与参考", isExpanded: Binding(get: { expanded == item.activity }, set: { expanded = $0 ? item.activity : nil })) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(item.activity.steps.enumerated()), id: \.offset) { index, step in Text("\(index + 1). \(step)").font(.callout).fixedSize(horizontal: false, vertical: true) }
                            Link("查看参考资料 ↗", destination: item.activity.source).font(.caption)
                            Button("体验这个活动") { store.startSession(activities: [item.activity]) }.disabled(store.sessionActive)
                        }.padding(.top, 12)
                    }
                    if item.activity == .pelvic { Text("盆底活动默认关闭。紧张或疼痛的盆底可能需要放松而非强化；是否练习以及剂量请个体化决定。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        HStack {
            Button("开始完整组合", systemImage: "play.fill") { store.startSession() }.buttonStyle(.borderedProminent).tint(intervalFill).disabled(store.enabledRoutine.isEmpty || store.sessionActive)
            Spacer()
            Button("恢复推荐组合") { reset = true }
        }.confirmationDialog("恢复默认活动、频率与目标？", isPresented: $reset) { Button("恢复组合") { store.preferences.routine = RoutineItem.defaults } }
        Text("每日目标是可调整的习惯目标，不是医学处方；0 表示不设每日目标，仍保留间隔提醒。护眼默认参考 20-20-20；每小时离屏 5–10 分钟参考 HSE。其余次数与组合是温和的产品默认值，没有唯一的科学最佳剂量。疼痛、眩晕或麻木时停止活动。").font(.caption).foregroundStyle(.secondary)
    }
    private func move(_ activity: Activity, by delta: Int) {
        guard let i = store.preferences.routine.firstIndex(where: { $0.activity == activity }) else { return }
        let target = i + delta
        guard store.preferences.routine.indices.contains(target) else { return }
        store.preferences.routine.swapAt(i, target)
    }
}
struct SessionView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Surface {
            if let item = store.currentItem {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("进行中 · \(store.sessionIndex + 1) / \(store.session.count)", systemImage: item.activity.symbol).font(.headline)
                        Spacer()
                        Button("结束这次活动", role: .cancel) { store.cancelSession() }
                    }
                    HStack(alignment: .top, spacing: 25) {
                        VStack(spacing: 8) {
                            Image(systemName: item.activity.symbol).font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.tint)
                            Text(clock).font(.system(size: 38, weight: .light, design: .rounded)).monospacedDigit()
                            Text(store.sessionPaused ? "已暂停" : "跟着自己的节奏").font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 150).accessibilityElement(children: .combine)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(item.activity.title).font(.title2.weight(.semibold))
                            Text(instruction(for: item)).font(.body).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                            Text(item.activity == .eyes ? "让视线离开屏幕，不必盯着倒计时。" : "以舒适为限；不适时随时结束。").font(.caption).foregroundStyle(.secondary)
                            Button(store.sessionPaused ? "继续" : "暂停", systemImage: store.sessionPaused ? "play.fill" : "pause.fill") { store.sessionPaused.toggle() }.buttonStyle(.bordered)
                        }
                    }
                    ProgressView(value: 1 - store.sessionRemaining / Double(item.durationSeconds)).tint(.accentColor)
                }
            } else if store.sessionFinished {
                HStack(spacing: 18) {
                    Image(systemName: "checkmark.circle").font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 6) { Text("给身体的这点时间，收到了。").font(.title3.weight(.medium)); Text("已记录完成的引导。准备好，再回到你的节奏。").foregroundStyle(.secondary) }
                    Spacer(); Button("完成") { store.cancelSession() }
                }
            }
        }
    }
    private var clock: String { let s = Int(ceil(store.sessionRemaining)); return String(format: "%02d:%02d", s / 60, s % 60) }
    private func instruction(for item: RoutineItem) -> String {
        let steps = item.activity.steps
        if item.activity == .eyes { return steps.joined(separator: "\n") }
        let progress = 1 - store.sessionRemaining / Double(item.durationSeconds)
        return steps[min(steps.count - 1, Int(progress * Double(steps.count)))]
    }
}
struct ReminderView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("间歇", systemImage: "leaf").font(.caption).foregroundStyle(.secondary); Spacer(); Button { store.dismissReminder() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("稍后提醒") }
            Text(title).font(.title3.weight(.semibold))
            Text(store.reminder?.reason ?? "").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button(store.reminder?.kind == .refocus ? "回到学习" : "开始活动") { store.acceptReminder() }.buttonStyle(.borderedProminent).tint(intervalFill); Button("5 分钟后") { store.dismissReminder() } }
        }.padding(22).frame(width: 350).tint(intervalAccent)
    }
    private var title: String { if case .rest(let activity) = store.reminder?.kind { return "现在，\(activity.title)一下？" }; return "要回到刚才的学习吗？" }
}
