import AppKit
import SwiftUI
import PauseCore

/// Floating always-on-top guide for a running activity group: which step is up,
/// the remaining time, pause/resume and end. Lives in its own non-activating
/// panel so the user can keep working while the guide stays visible.
@MainActor final class SessionPanelController {
    private var panel: NSPanel?

    func show(store: AppStore) {
        let panel: NSPanel
        if let existing = self.panel { panel = existing }
        else { panel = makePanel(); self.panel = panel }
        panel.contentView = NSHostingView(rootView: SessionGuideView(store: store, onClose: { [weak self] in self?.hideAndCancel(store) }))
        panel.orderFrontRegardless()
        position(panel)
    }

    /// Safety net on every syncSession tick: if the session ended without the
    /// normal cancel path (e.g. eraseData), the floating guide closes itself.
    func sync(store: AppStore) {
        guard panel != nil else { return }
        if !store.sessionActive && !store.sessionFinished {
            hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func hideAndCancel(_ store: AppStore) {
        hide()
        // The view's close button means "end this group", matching the main window.
        if store.sessionActive || store.sessionFinished { store.cancelSession() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 190), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        return panel
    }

    /// Keeps the panel at the top-right of the main screen, below the menu bar.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - panel.frame.height - 12))
    }
}

struct SessionGuideView: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let item = store.currentItem {
                guideHeader(item)
                guideBody(item)
            } else if store.sessionFinished {
                finishedBody
            } else {
                // Transient: the panel closes itself on the next sync tick.
                Text("…").font(.caption)
            }
        }
        .padding(18)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
        )
        .tint(intervalAccent)
    }

    private func guideHeader(_ item: RoutineItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.activity.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(intervalAccent)
                .opacity(pulse ? 1 : 0.55)
            Text("进行中 · \(store.sessionIndex + 1) / \(max(1, store.session.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("结束这次活动")
        }
        .onAppear { pulse = true }
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)
    }

    @ViewBuilder
    private func guideBody(_ item: RoutineItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.activity.title).font(.headline)
            Text(sessionClock(store.sessionRemaining))
                .font(.system(size: 34, weight: .light, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: 1 - store.sessionRemaining / Double(max(1, item.durationSeconds)))
                .tint(intervalAccent)
            HStack(spacing: 10) {
                Button(store.sessionPaused ? "继续" : "暂停") { store.toggleSessionPause() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text(store.sessionPaused ? "已暂停" : "离开屏幕，跟着节奏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var finishedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "checkmark.circle").foregroundStyle(intervalAccent); Text("这组活动已完成").font(.headline); Spacer(); Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            Text("给身体的这点时间，收到了。").font(.caption).foregroundStyle(.secondary)
            Button("知道了") { onClose() }.buttonStyle(.bordered).controlSize(.small)
        }
    }
}
