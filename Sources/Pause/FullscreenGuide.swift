import AppKit
import SwiftUI
import PauseCore

/// Immersive fullscreen guide for a running activity group: a borderless
/// non-activating panel covering the main screen that stages the current
/// activity (breathe → focus → settle) instead of showing a countdown card.
/// Pure presentation: every displayed value derives from the AppStore's
/// published session fields, and the engine owns all timing state.
@MainActor final class FullscreenGuideController {
    private var panel: GuideOverlayPanel?
    private var keyDownMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?

    func show(store: AppStore) {
        // The floating guide and the fullscreen guide are mutually exclusive:
        // fullscreen takes over, so the "keep working" companion panel steps out.
        store.hideSessionGuide()
        guard panel == nil else { return }
        // Theoretical unreachable (a GUI process always has a main screen);
        // defensive so a nil screen can never produce a degenerate frame.
        guard let screen = NSScreen.main else { return }
        let panel = GuideOverlayPanel(contentRect: screen.frame)
        panel.contentView = NSHostingView(rootView: FullscreenGuideView(store: store))
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installKeyDownMonitor(store: store)
        installScreenChangeObserver(store: store)
    }

    /// Re-anchor the cover when display geometry changes. Sleep/wake and
    /// monitor changes fire NSApplication.didChangeScreenParametersNotification;
    /// without this the borderless panel keeps a stale frame (or drifts). If
    /// the current main screen disappears entirely, collapse through
    /// hideFullscreenGuide() so the published flag stays in lockstep with the
    /// panel's lifecycle. Removal is folded into hide() so both exit paths
    /// (Esc and cancel) tear the observer down.
    private func installScreenChangeObserver(store: AppStore) {
        removeScreenChangeObserver()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak store, weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                guard let screen = NSScreen.main else {
                    store?.hideFullscreenGuide()
                    return
                }
                panel.setFrame(screen.frame, display: true)
            }
        }
    }

    private func removeScreenChangeObserver() {
        if let screenChangeObserver { NotificationCenter.default.removeObserver(screenChangeObserver) }
        screenChangeObserver = nil
    }

    /// Safety net on every syncSession tick: if the session ended without the
    /// normal hide path (e.g. eraseData → cancelSession), the fullscreen guide
    /// closes itself. Mirrors SessionPanelController.sync.
    func sync(store: AppStore) {
        guard panel != nil else { return }
        if !store.sessionActive && !store.sessionFinished {
            hide()
        }
    }

    /// Hides and tears down the fullscreen guide. Must be idempotent: Esc can
    /// arrive through both .onExitCommand and the local keyDown monitor, and
    /// hideFullscreenGuide may run again via cancelSession/sync.
    func hide() {
        removeKeyDownMonitor()
        removeScreenChangeObserver()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Esc fallback and spacebar → pause toggle. A local monitor only sees this
    /// process's events, so it must stay scoped to exactly the fullscreen state:
    /// installed on show, removed on hide, and pass-through whenever the panel
    /// is not the key window (otherwise it would swallow the main window's or
    /// floating guide's spacebar). Returning nil swallows the event.
    private func installKeyDownMonitor(store: AppStore) {
        removeKeyDownMonitor()
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store, weak self] event in
            guard let self, self.panel?.isKeyWindow == true, store?.fullscreenGuideVisible == true else { return event }
            if event.keyCode == 53 { // Esc: collapse the fullscreen guide
                store?.hideFullscreenGuide()
                return nil
            }
            if event.keyCode == 49 { // Space: toggle pause/resume
                store?.toggleSessionPause()
                return nil
            }
            return event
        }
    }

    private func removeKeyDownMonitor() {
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        keyDownMonitor = nil
    }
}

/// Borderless fullscreen-covering panel. Both overrides are load-bearing:
/// - `canBecomeKey` defaults to false on NSPanel; without it makeKeyAndOrderFront
///   silently fails and Esc/onExitCommand never route.
/// - `hidesOnDeactivate` defaults to true on NSPanel; the fullscreen guide must
///   survive the user clicking another app or walking away (SessionPanel.swift
///   sets the same override for the same reason).
@MainActor final class GuideOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
    }
}

/// The fullscreen guide's SwiftUI content. Deliberately free of engine writes:
/// it reads only published session fields and derives step state from the
/// global progress (the engine keeps a single remaining clock and no per-step
/// state, so derivation is the only stateless, pause-safe option).
struct FullscreenGuideView: View {
    @ObservedObject var store: AppStore
    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            if let item = store.currentItem {
                FullscreenActivityView(store: store, item: item)
                    .id(item.activity)
                    .transition(.opacity)
            } else if store.sessionFinished {
                finishedContent.transition(.opacity)
            } else {
                // Transient: the controller's sync closes the panel on the next tick.
                Text("…").font(.title3).foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        .tint(intervalAccent)
        .opacity(appeared ? 1 : 0)
        .onExitCommand { store.hideFullscreenGuide() }
        .animation(.easeInOut(duration: 0.5), value: store.currentItem?.activity)
        .onAppear { withAnimation(.easeOut(duration: 0.4)) { appeared = true } }
        .accessibilityElement(children: .contain)
    }

    private var finishedContent: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(intervalAccent)
            Text("这组活动已完成").font(.system(size: 34, weight: .semibold))
            Text("给身体的这点时间，收到了。").font(.title3).foregroundStyle(.secondary)
            Button("回到刚才的事") { store.cancelSession() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 60)
    }
}

/// One activity, staged: symbol-focused center, per-step rhythm below.
private struct FullscreenActivityView: View {
    @ObservedObject var store: AppStore
    let item: RoutineItem
    @State private var symbolShown = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                stage
                Spacer(minLength: 0)
                footer
            }
            .padding(.vertical, 60)
            .padding(.horizontal, 80)
            // A locked screen really has stopped the clock: dim the staged
            // content to a static shadow instead of animating over a paused
            // engine ("还在计时"的错觉) — the overlay states the reason.
            .opacity(store.sessionPauseReason == .screenUnavailable ? 0.35 : 1)
            if store.sessionPaused {
                PausedOverlayView(store: store)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.sessionPaused)
        // Symbol entrance per activity switch: scale 0.92 → 1, easeOut 0.5 s.
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { symbolShown = true } }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text(item.activity.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.primary)
            Text("进行中 · \(store.sessionIndex + 1) / \(max(1, store.session.count))")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            VStack(alignment: .trailing, spacing: 4) {
                Button { store.hideFullscreenGuide() } label: {
                    Label("收起全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                Text("esc").font(.caption).foregroundStyle(.tertiary)
            }
            // The visible collapse button is the guaranteed exit path: it must
            // stay reachable even when this panel is not the key window (the
            // user clicked away; see GuideOverlayPanel.hidesOnDeactivate).
            .accessibilityElement(children: .contain)
            .accessibilityLabel("收起全屏指引")
        }
    }

    private var stage: some View {
        Group {
            switch item.activity {
            case .eyes: EyesStage(store: store, item: item)
            case .wrists: WristsStage(store: store, item: item)
            case .shoulders: ShouldersStage(store: store, item: item)
            case .stand: StandStage(store: store, item: item)
            case .pelvic: PelvicStage(store: store, item: item)
            }
        }
        .scaleEffect(symbolShown ? 1 : 0.92)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            if let next = nextItem {
                Text("接下来 · \(next.activity.title)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            StepRailView(activity: item.activity, activeIndex: stepIndex)
            if item.activity == .stand {
                // 32pt clock pinned to the bottom: the stand activity keeps its
                // distance from the screen, so the number must stay readable
                // without dominating the composition.
                Text(sessionClock(store.sessionRemaining))
                    .font(.system(size: 32, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .foregroundStyle(.secondary)
            }
            // Rhythm/status phrase only; all medical content stays in the
            // activity's own step texts, presented verbatim in the stages.
            if item.activity != .eyes {
                Text("以舒适为限；不适时随时结束。").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.3), value: store.sessionIndex)
    }

    private var nextItem: RoutineItem? {
        let next = store.sessionIndex + 1
        guard store.session.count > 1, next < store.session.count, store.sessionRemaining <= 5 else { return nil }
        return store.session[next]
    }

    // MARK: Derived step state (no per-step engine state exists or may be added)

    /// Global progress through the whole activity, same formula as the main
    /// window and floating guide (RoutineView/SessionPanel).
    private var activityProgress: Double {
        1 - store.sessionRemaining / Double(max(1, item.durationSeconds))
    }
    private var stepIndex: Int {
        derivedStepIndex(activity: item.activity, durationSeconds: item.durationSeconds, progress: activityProgress)
    }
}

/// Pause-cover line for the reason the session clock stopped. Internal so the
/// reason→phrase mapping is testable at its single owning seam (the view only
/// calls this; the text lives in one place).
func pauseCoverSubtitle(reason: SessionEngine.PauseReason?) -> String {
    switch reason {
    case .user: "歇一会儿没关系，准备好再继续。"
    case .screenUnavailable: "屏幕暂时不可用。回来后会自动接着进行。"
    case .timingGap: "时间刚好像跳了一拍。稍候自动继续。"
    case nil: "已暂停。"
    }
}

// MARK: - Derived step math (shared by the stage views)
// Internal (like sessionClock in RoutineView.swift) so the engine↔presentation
// lockstep is testable at its real seam; the bodies stay single-source.

/// Normalized per-step durations: raw weights are absolute shares, so dividing
/// by their sum (never by 1) is what makes wrists' [1,1,1,1] mean "four equal
/// quarters" instead of "each step the whole duration". Falls back to even
/// segments when weights are empty or sum to ≤ 0.
func normalizedStepDurations(activity: Activity, durationSeconds: Int) -> [Double] {
    let weights = activity.stepWeights
    let total = weights.reduce(0, +)
    guard total > 0, !weights.isEmpty else {
        let even = 1.0 / Double(max(1, activity.steps.count))
        return Array(repeating: even * Double(max(1, durationSeconds)), count: activity.steps.count)
    }
    return weights.map { $0 / total * Double(max(1, durationSeconds)) }
}

/// Current step derived from global progress against the activity's weighted
/// step boundaries — the same shares `normalizedStepDurations` and StepRailView
/// display, so the staged art, the rail highlight and the "这一步 · 约 N 秒"
/// caption can never disagree about which step is up. Equal division would
/// desync them whenever the weights are uneven (pelvic at 60 s: its weighted
/// step ① ends at 12 s, but an equal-division index kept it staged until 20 s,
/// pinning the caption at "约 0 秒" for 8 s). Walking the cumulative lengths
/// (instead of scaling the index) also clamps the progress → 1 boundary: the
/// index can never reach stepCount.
func derivedStepIndex(activity: Activity, durationSeconds: Int, progress: Double) -> Int {
    let durations = normalizedStepDurations(activity: activity, durationSeconds: durationSeconds)
    let elapsed = max(0, progress) * Double(max(1, durationSeconds))
    var accumulated = 0.0
    for (index, length) in durations.enumerated() {
        accumulated += length
        if elapsed < accumulated { return index }
    }
    return max(0, durations.count - 1)
}

/// Seconds left in the current step, for the "这一步 · 约 N 秒" caption.
/// stepIndex is expected to come from `derivedStepIndex` over the same
/// activity/duration, so the two always describe the same step and the caption
/// only reads 0 at the very last second of the activity.
func derivedStepRemaining(activity: Activity, durationSeconds: Int, progress: Double, stepIndex: Int) -> Int {
    let durations = normalizedStepDurations(activity: activity, durationSeconds: durationSeconds)
    guard durations.indices.contains(stepIndex) else { return 0 }
    let elapsedInStep = max(0, progress) * Double(max(1, durationSeconds))
        - durations.prefix(stepIndex).reduce(0, +)
    let within = min(1, max(0, elapsedInStep / max(1, durations[stepIndex])))
    return Int(ceil(max(0, durations[stepIndex] * (1 - within))))
}

/// Segmented capsule rail showing the normalized step shares; the active
/// segment highlights so composition reads at a glance.
struct StepRailView: View {
    let activity: Activity
    let activeIndex: Int
    var body: some View {
        let weights = activity.stepWeights
        let total = max(weights.reduce(0, +), 0.0001)
        HStack(spacing: 8) {
            ForEach(Array(activity.steps.enumerated()), id: \.offset) { index, _ in
                let share = weights.indices.contains(index) ? weights[index] / total : 1 / Double(max(1, activity.steps.count))
                Capsule()
                    .fill(index == activeIndex ? intervalAccent : intervalAccent.opacity(0.18))
                    .frame(width: max(28, 64 * share), height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(activeIndex + 1) 步，共 \(activity.steps.count) 步")
    }
}

/// Shared progress ring: trim-driven, linear animation slightly longer than the
/// 1 Hz tick period (0.2 s tolerance) so per-second jumps move smoothly.
private struct GuideProgressRing<Content: View>: View {
    let progress: Double
    let lineWidth: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            Circle().stroke(intervalAccent.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(intervalAccent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1.05), value: progress)
            content()
        }
    }
}

/// Pause cover: material over the whole guide with a reason-specific line.
/// Frozen semantics live in the engine (remaining does not advance while
/// paused); here we only present them honestly.
private struct PausedOverlayView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("已暂停").font(.system(size: 28, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("继续") { store.toggleSessionPause() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Button("收起全屏") { store.hideFullscreenGuide() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("已暂停，\(subtitle)")
    }
    private var subtitle: String { pauseCoverSubtitle(reason: store.sessionPauseReason) }
}

// MARK: - Per-activity stages

/// eyes: breathe to the distance. No on-screen countdown (the step text promises
/// "无需盯着倒计时"); completion stays perceivable through the global ring, and
/// VoiceOver announces the remaining seconds.
private struct EyesStage: View {
    @ObservedObject var store: AppStore
    let item: RoutineItem
    var body: some View {
        VStack(spacing: 36) {
            GuideProgressRing(progress: progress, lineWidth: 10) {
                if store.sessionPaused {
                    // Frozen frame: the clock really is stopped; a breathing
                    // animation would lie about time passing.
                    Circle().fill(intervalAccent).frame(width: 18, height: 18)
                } else if stepIndex == 0 {
                    BreathDotView()
                } else {
                    EyePulseView()
                }
            }
            .frame(width: 320, height: 320)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("远眺护眼，还剩 \(Int(store.sessionRemaining.rounded(.up))) 秒")
            Text(item.activity.steps[stepIndex])
                .font(.system(size: 20))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Text("看向远处就好。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    private var progress: Double { 1 - store.sessionRemaining / Double(max(1, item.durationSeconds)) }
    private var stepIndex: Int { derivedStepIndex(activity: item.activity, durationSeconds: item.durationSeconds, progress: progress) }
}

/// Slow breathing dot for eyes step ①: 4 s swell + 4 s settle ≈ 8 s cycle.
private struct BreathDotView: View {
    var body: some View {
        PhaseAnimator([false, true]) { breathing in
            Circle()
                .fill(intervalAccent)
                .frame(width: 18, height: 18)
                .scaleEffect(breathing ? 2.2 : 1.0)
                .opacity(breathing ? 0.75 : 1)
        } animation: { _ in
            .easeInOut(duration: 4)
        }
    }
}

/// eyes step ②: the gaze softens — 0.9 → 0.4 opacity pulse over 3 s.
private struct EyePulseView: View {
    var body: some View {
        PhaseAnimator([false, true]) { dimmed in
            Image(systemName: "eye.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(intervalAccent)
                .opacity(dimmed ? 0.4 : 0.9)
        } animation: { _ in
            .easeInOut(duration: 3)
        }
    }
}

/// wrists: four equal steps, mirrored hand stretches. Step ③'s stretch uses
/// `hand.point.right` — `hand.point.up.right` does not exist in the macOS 14
/// symbol library (verified via NSImage(systemSymbolName:) == nil).
private struct WristsStage: View {
    @ObservedObject var store: AppStore
    let item: RoutineItem
    var body: some View {
        VStack(spacing: 32) {
            GuideProgressRing(progress: progress, lineWidth: 10) {
                if store.sessionPaused {
                    StaticStepSymbol(activity: item.activity, stepIndex: stepIndex)
                } else {
                    // Gentle ±6 pt sway suggests "不弹震"; 4 s per side.
                    PhaseAnimator([false, true], trigger: stepIndex) { outward in
                        Image(systemName: stepSymbolName)
                            .font(.system(size: 96, weight: .light))
                            .foregroundStyle(intervalAccent)
                            .offset(x: outward ? 6 : -6)
                    } animation: { _ in
                        .easeInOut(duration: 4)
                    }
                }
            }
            .frame(width: 340, height: 340)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("手腕拉伸，第 \(stepIndex + 1) 步，还剩 \(Int(store.sessionRemaining.rounded(.up))) 秒")
            HStack(spacing: 44) {
                Text("左").font(.system(size: 52, weight: .light)).foregroundStyle(leftStyle)
                Text("右").font(.system(size: 52, weight: .light)).foregroundStyle(rightStyle)
            }
            Text(item.activity.steps[stepIndex])
                .font(.system(size: 20))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
            Text("这一步 · 约 \(stepRemaining) 秒")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    private var progress: Double { 1 - store.sessionRemaining / Double(max(1, item.durationSeconds)) }
    private var stepIndex: Int { derivedStepIndex(activity: item.activity, durationSeconds: item.durationSeconds, progress: progress) }
    private var stepRemaining: Int {
        derivedStepRemaining(activity: item.activity, durationSeconds: item.durationSeconds, progress: progress, stepIndex: stepIndex)
    }
    private var stepSymbolName: String {
        let symbols = item.activity.stepSymbols
        return symbols.indices.contains(stepIndex) ? symbols[stepIndex] : item.activity.symbol
    }
    // Step ② stretches the left arm, step ③ the right; the active side reads
    // in the accent color, the other side recedes.
    private var leftStyle: AnyShapeStyle { stepIndex == 1 ? AnyShapeStyle(intervalAccent) : AnyShapeStyle(.quaternary) }
    private var rightStyle: AnyShapeStyle { stepIndex == 2 ? AnyShapeStyle(intervalAccent) : AnyShapeStyle(.quaternary) }
}

/// shoulders: breathe the figure, alternate the turn sides, settle with a slow
/// quarter-sway that never completes a circle (the step text forbids it).
private struct ShouldersStage: View {
    @ObservedObject var store: AppStore
    let item: RoutineItem
    var body: some View {
        VStack(spacing: 32) {
            GuideProgressRing(progress: progress, lineWidth: 10) {
                if store.sessionPaused {
                    StaticStepSymbol(activity: item.activity, stepIndex: stepIndex)
                } else {
                    switch stepIndex {
                    case 0:
                        // 96pt breathing scale 1 ↔ 1.04, 6 s cycle.
                        PhaseAnimator([false, true], trigger: stepIndex) { breathing in
                            Image(systemName: "figure.flexibility")
                                .font(.system(size: 96, weight: .light))
                                .foregroundStyle(intervalAccent)
                                .scaleEffect(breathing ? 1.04 : 1.0)
                        } animation: { _ in
                            .easeInOut(duration: 3)
                        }
                    case 1:
                        // Left/right alternation, 5 s per phase: "停留约 5 秒".
                        PhaseAnimator([false, true], trigger: stepIndex) { left in
                            ZStack {
                                Image(systemName: "arrow.left")
                                    .font(.system(size: 64, weight: .light))
                                    .foregroundStyle(left ? AnyShapeStyle(intervalAccent) : AnyShapeStyle(.quaternary))
                                    .offset(x: -46)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 64, weight: .light))
                                    .foregroundStyle(left ? AnyShapeStyle(.quaternary) : AnyShapeStyle(intervalAccent))
                                    .offset(x: 46)
                            }
                        } animation: { _ in
                            .easeInOut(duration: 5)
                        }
                    default:
                        // 0 → 15° → 0 slow sway, never a full circle.
                        PhaseAnimator([false, true], trigger: stepIndex) { turned in
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 96, weight: .light))
                                .foregroundStyle(intervalAccent)
                                .rotationEffect(.degrees(turned ? 15 : 0))
                        } animation: { _ in
                            .easeInOut(duration: 2)
                        }
                    }
                }
            }
            .frame(width: 340, height: 340)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("肩颈放松，第 \(stepIndex + 1) 步，还剩 \(Int(store.sessionRemaining.rounded(.up))) 秒")
            Text(item.activity.steps[stepIndex])
                .font(.system(size: 20))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
            Text("这一步 · 约 \(stepRemaining) 秒")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    private var progress: Double { 1 - store.sessionRemaining / Double(max(1, item.durationSeconds)) }
    private var stepIndex: Int { derivedStepIndex(activity: item.activity, durationSeconds: item.durationSeconds, progress: progress) }
    private var stepRemaining: Int {
        derivedStepRemaining(activity: item.activity, durationSeconds: item.durationSeconds, progress: progress, stepIndex: stepIndex)
    }
}

/// Reusable static symbol for paused states and simple stages.
private struct StaticStepSymbol: View {
    let activity: Activity
    let stepIndex: Int
    var body: some View {
        let symbols = activity.stepSymbols
        let name = symbols.indices.contains(stepIndex) ? symbols[stepIndex] : activity.symbol
        return Image(systemName: name)
            .font(.system(size: 96, weight: .light))
            .foregroundStyle(intervalAccent)
    }
}

/// stand: the most "step back" activity — generous whitespace, the focus small
/// and low, the clock readable at the bottom (the frozen 32pt number is how a
/// returning user reads the paused state, since 225 of 300 s are the drift step).
private struct StandStage: View {
    @ObservedObject var store: AppStore
    let item: RoutineItem
    @State private var risen = false
    var body: some View {
        VStack(spacing: 28) {
            GuideProgressRing(progress: progress, lineWidth: 8) {
                if store.sessionPaused {
                    StaticStepSymbol(activity: item.activity, stepIndex: stepIndex)
                        .font(.system(size: 56, weight: .light))
                } else if stepIndex == 0 {
                    // One-time scale-in, not a loop: standing up happens once.
                    Image(systemName: "arrow.up.to.line")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(intervalAccent)
                        .scaleEffect(risen ? 1 : 0.6)
                        .opacity(risen ? 1 : 0.2)
                } else if stepIndex == 1 {
                    // A small dot drifting across a ~240 pt wide path: walking,
                    // abstracted. 4.5 s each way, 9 s round trip.
                    PhaseAnimator([false, true], trigger: stepIndex) { outward in
                        Circle()
                            .fill(intervalAccent)
                            .frame(width: 14, height: 14)
                            .offset(x: outward ? 120 : -120)
                    } animation: { _ in
                        .easeInOut(duration: 4.5)
                    }
                } else {
                    // leaf + breathing circle settle.
                    PhaseAnimator([false, true], trigger: stepIndex) { breathing in
                        ZStack {
                            Circle().stroke(intervalAccent.opacity(0.35), lineWidth: 3)
                                .frame(width: 72, height: 72)
                                .scaleEffect(breathing ? 1.12 : 1.0)
                            Image(systemName: "leaf")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(intervalAccent)
                        }
                    } animation: { _ in
                        .easeInOut(duration: 3)
                    }
                }
            }
            .frame(width: 300, height: 300)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("起身走动，第 \(stepIndex + 1) 步，还剩 \(Int(store.sessionRemaining.rounded(.up))) 秒")
            // Step ② gets the one allowed new phrase; steps ①③ reuse the
            // verbatim step texts (including "不便站立时可改为坐姿活动").
            Text(stepIndex == 1 ? "走一走，换一种姿势" : item.activity.steps[stepIndex])
                .font(.system(size: 20))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { risen = true } }
    }
    private var progress: Double { 1 - store.sessionRemaining / Double(max(1, item.durationSeconds)) }
    private var stepIndex: Int { derivedStepIndex(activity: item.activity, durationSeconds: item.durationSeconds, progress: progress) }
}

/// pelvic: the 2 s lift / 4 s release rhythm is the core. One TimelineView
/// drives BOTH the visual phase and the caption so they can never drift apart
/// (deriving the caption from sessionRemaining instead would decouple them
/// during pauses); .animation(paused:) freezes it honestly. Rhythm restarts
/// from phase zero on resume — accepted by design.
private struct PelvicStage: View {
    @ObservedObject var store: AppStore
    let item: RoutineItem
    static let cycle: Double = 6 // 2 s lift + 4 s release, per Models.swift
    var body: some View {
        VStack(spacing: 32) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: store.sessionPaused)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.cycle)
                rhythmCircle(lifting: phase < 2)
            }
            .frame(width: 340, height: 340)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("盆底觉察，第 \(stepIndex + 1) 步，还剩 \(Int(store.sessionRemaining.rounded(.up))) 秒")
            Text(item.activity.steps[stepIndex])
                .font(.system(size: 20))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
            Text("这一步 · 约 \(stepRemaining) 秒")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
    /// Circle and caption share this one phase source.
    private func rhythmCircle(lifting: Bool) -> some View {
        VStack(spacing: 14) {
            Circle()
                .stroke(intervalAccent, lineWidth: 8)
                .frame(width: 150, height: 150)
                .scaleEffect(lifting ? 0.82 : 1.0)
                .opacity(lifting ? 0.9 : 0.6)
            Text(lifting ? "轻轻提起…" : "完全放松…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: lifting ? 2 : 4), value: lifting)
    }
    private var progress: Double { 1 - store.sessionRemaining / Double(max(1, item.durationSeconds)) }
    private var stepIndex: Int { derivedStepIndex(activity: item.activity, durationSeconds: item.durationSeconds, progress: progress) }
    private var stepRemaining: Int {
        derivedStepRemaining(activity: item.activity, durationSeconds: item.durationSeconds, progress: progress, stepIndex: stepIndex)
    }
}
