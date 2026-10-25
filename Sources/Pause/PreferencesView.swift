import SwiftUI
import PauseCore
import ServiceManagement

struct PreferencesView: View {
    @ObservedObject var store: AppStore
    @State private var bundleID = ""
    @State private var category: AppCategory = .distracting
    @State private var key = ""
    @State private var keyStatus = ""
    @State private var cloudConsent = false
    var body: some View {
        Heading(title: "按你的节奏来。", subtitle: "把判断交给本机，把选择留给自己。")
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Text("监测与权限").font(.headline)
                Toggle("启用本地监测", isOn: $store.preferences.monitoring).disabled(!store.hasConsented)
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("键盘频率统计"); Text(store.keyboardAvailable ? "计数已启用 · 不记录输入内容" : "需要 macOS 输入监控权限；安全输入可能使计数暂时不可用").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if store.preferences.keyboardEnabled { Button("关闭计数") { store.preferences.keyboardEnabled = false } }
                    Button("授权 / 重新检查") { store.requestKeyboard() }.disabled(!store.preferences.monitoring)
                }
                HStack { Button("打开输入监控设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }; Text("授权后若未生效，请退出并重新打开间歇。").font(.caption).foregroundStyle(.secondary) }
                Divider()
                Toggle("活动完成时播放轻提示（便于远眺时知道结束）", isOn: $store.preferences.completionSound)
                Toggle("登录时启动", isOn: Binding(get: { store.loginStatus == .enabled }, set: { store.setLogin(enabled: $0) }))
                if store.loginStatus == .requiresApproval { Button("需要在系统设置允许登录启动") { SMAppService.openSystemSettingsLoginItems() } }
                Text("关闭窗口后仍留在菜单栏；可从菜单栏完全退出。").font(.caption).foregroundStyle(.secondary)
            }
        }
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Text("判断与免打扰").font(.headline)
                Toggle("根据应用类别判断情境", isOn: $store.preferences.contextDetection)
                Toggle("保护全屏场景", isOn: $store.preferences.protectFullscreen)
                Toggle("麦克风被使用时暂停提醒", isOn: $store.preferences.protectMicrophone)
                Toggle("学习时提示标记的分心应用", isOn: $store.preferences.distractionHints)
                Text("不会读取屏幕内容或音频。全屏、会议应用及麦克风占用只是保守线索；未全屏的网页视频和浏览器会议请用手动免打扰。学习提醒仅在你选择学习模式并标记分心应用后触发。").font(.caption).foregroundStyle(.secondary)
                Stepper("高输入负荷阈值：\(store.preferences.highTypingThreshold) 次 / 分钟", value: $store.preferences.highTypingThreshold, in: 30...600, step: 30)
                Toggle("启用安静时段", isOn: $store.preferences.quietHours)
                if store.preferences.quietHours {
                    HStack { Picker("从", selection: $store.preferences.quietStart) { ForEach(0..<24) { Text("\($0):00").tag($0) } }; Picker("到", selection: $store.preferences.quietEnd) { ForEach(0..<24) { Text("\($0):00").tag($0) } } }
                }
                Button("恢复被稍后推迟的提醒") { store.resumeReminders() }
            }
        }
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Text("应用分类").font(.headline)
                Text("只匹配应用 Bundle ID，不读取网页或窗口标题。同一个浏览器的不同网页无法单独分类。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("例如 com.example.App", text: $bundleID).textFieldStyle(.roundedBorder)
                    Picker("类别", selection: $category) { ForEach(AppCategory.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 160)
                    Button("添加") {
                        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.preferences.appRules.removeAll { $0.bundleID == id }
                        store.preferences.appRules.append(AppRule(bundleID: id, category: category)); bundleID = ""
                    }.disabled(!validBundleID)
                }
                ForEach(store.preferences.appRules) { rule in HStack { Text(rule.bundleID).font(.callout.monospaced()); Spacer(); Text(rule.category.title).foregroundStyle(.secondary); Button("移除") { store.preferences.appRules.removeAll { $0.id == rule.id } } } }
                DisclosureGroup("从正在运行的应用选择") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            if let id = app.bundleIdentifier { Button("\(app.localizedName ?? id) · \(id)") { bundleID = id }.buttonStyle(.link) }
                        }
                    }.padding(.top, 10)
                }
            }
        }
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("可选的云端时机建议").font(.headline); Spacer(); Toggle("启用", isOn: Binding(get: { store.preferences.cloudEnabled }, set: { if $0 {
                    do {
                        _ = try CloudAdvisor.endpoint(store.preferences.cloudEndpoint)
                        guard !store.preferences.cloudModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !(APIKey.load() ?? "").isEmpty else { throw CloudError.missingConfiguration }
                        cloudConsent = true
                    } catch { store.error = error.localizedDescription }
                } else { store.preferences.cloudEnabled = false } })).labelsHidden() }
                Text("默认关闭。开启后仅在本地准备提醒时，向你指定的服务发送：连续使用分钟数、每分钟按键数、空闲秒数、手动情境、应用类别和拟进行活动。不会发送应用名称、Bundle ID、按键内容或每日记录。服务方可能留存这些摘要。").font(.callout).foregroundStyle(.secondary)
                TextField("HTTPS Chat Completions 地址", text: $store.preferences.cloudEndpoint).textFieldStyle(.roundedBorder)
                TextField("模型名称", text: $store.preferences.cloudModel).textFieldStyle(.roundedBorder)
                HStack { SecureField("API Key（仅保存于 macOS 钥匙串）", text: $key).textFieldStyle(.roundedBorder); Button("保存 Key") { do { try APIKey.save(key); key = ""; keyStatus = "已保存到钥匙串" } catch { keyStatus = error.localizedDescription } }.disabled(key.isEmpty); Button("删除 Key") { do { try APIKey.delete(); keyStatus = "已删除" } catch { keyStatus = error.localizedDescription } } }
                if !keyStatus.isEmpty { Text(keyStatus).font(.caption).foregroundStyle(.secondary) }
                Text(store.cloudStatus).font(.caption).foregroundStyle(.secondary)
                Text("兼容 OpenAI Chat Completions 的 HTTPS 服务。云端只能允许或延后一次（5 分钟），不能绕过保护；8 秒超时或响应异常回退本地。API Key 只发给当前填写的地址，修改地址前请核对服务方。").font(.caption).foregroundStyle(.secondary)
            }
        }.confirmationDialog("允许向所填写的云端服务发送上面列出的使用摘要？", isPresented: $cloudConsent, titleVisibility: .visible) { Button("允许并开启云端建议") { store.preferences.cloudEnabled = true }; Button("保持纯本地", role: .cancel) {} }
        .onAppear { store.loginStatus = SMAppService.mainApp.status }
    }
    private var validBundleID: Bool { bundleID.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil }
    private var runningApps: [NSRunningApplication] { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") } }
}
struct PrivacyView: View {
    @ObservedObject var store: AppStore
    @State private var erase = false
    var body: some View {
        Heading(title: "你的数据，留在你这里。", subtitle: "本地是默认选项，不需要账户，也没有遥测、广告或分析 SDK。")
        Surface {
            VStack(alignment: .leading, spacing: 20) {
                privacyRow("仅计次数，不读文字", "键盘授权完全可选。监听只读按键事件的数量，不提取键值、字符或组合键。", "keyboard")
                Divider()
                privacyRow("仅判断情境，不看内容", "瞬时读取前台应用 Bundle ID、窗口尺寸与默认输入设备运行状态，转换为类别；不存储应用使用轨迹，不录音或截图。", "rectangle.on.rectangle")
                Divider()
                privacyRow("只存每日汇总", "最近 30 天的屏幕使用估算、按键总数、活动完成次数和提醒次数，以及你的偏好。原始事件不落盘。", "externaldrive")
                Divider()
                privacyRow("云端由你决定", "默认不联网。开启云端后仅发送偏好设置中列出的摘要。Key 存于本机钥匙串，导出文件不包含 Key。", "cloud")
            }
        }
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Text("管理本地数据").font(.headline)
                Text("存储位置：~/Library/Application Support/Interval/state.json").font(.caption.monospaced()).textSelection(.enabled)
                HStack { Button("导出本地记录", systemImage: "square.and.arrow.up") { store.exportData() }; Spacer(); Button("清除所有数据与 Key", role: .destructive) { erase = true } }
            }
        }.confirmationDialog("删除最近 30 天记录、设置和钥匙串 Key，并停止监测？", isPresented: $erase, titleVisibility: .visible) { Button("清除并停止", role: .destructive) { store.eraseData() }; Button("取消", role: .cancel) {} }
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                Text("关于默认建议").font(.headline)
                Text("间歇帮助你形成休息习惯，不能诊断疲劳或确认注意力状态。活动完成代表完成了计时引导，不代表传感器验证了动作。手腕疼痛不应用强拉伸来处理；持续不适请寻求专业意见。").font(.callout).foregroundStyle(.secondary)
                Link("AAO · 屏幕与眼疲劳", destination: Activity.eyes.source)
                Link("HSE · 显示屏工作与休息", destination: Activity.stand.source)
                Link("NHS · 坐姿活动", destination: Activity.shoulders.source)
            }
        }
    }
    private func privacyRow(_ title: String, _ description: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 16) { Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30); VStack(alignment: .leading, spacing: 7) { Text(title).font(.headline); Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
    }
}
