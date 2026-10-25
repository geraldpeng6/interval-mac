import AppKit
import CoreAudio
import PauseCore

/// Only the count is retained. Never reads keyCode, characters, window titles or URLs.
@MainActor final class Sensors {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var count = 0
    private var samples: [(TimeInterval, Int)] = []
    private var previousCategory: AppCategory = .neutral
    private var categorySince = ProcessInfo.processInfo.systemUptime
    private var screenAwake = true
    private var unlocked = true
    private var observers: [NSObjectProtocol] = []
    var keyboardAvailable: Bool { tap != nil && CGPreflightListenEventAccess() }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.screenAwake = false } })
        observers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.screenAwake = true } })
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.screenAwake = false } })
        let dc = DistributedNotificationCenter.default()
        observers.append(dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.unlocked = false } })
        observers.append(dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.unlocked = true } })
    }
    func startKeyboard(request: Bool) {
        guard tap == nil else { return }
        if !CGPreflightListenEventAccess() {
            if request { _ = CGRequestListenEventAccess() }
            return
        }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<Sensors>.fromOpaque(info).takeUnretainedValue()
            // Tap is scheduled on the main run loop; all counts stay on that thread.
            MainActor.assumeIsolated {
                if type == .keyDown { owner.count += 1 }
                else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
                                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    func stopKeyboard() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; count = 0; samples = []
    }
    func read(preferences p: Preferences) -> (Signal, Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = count; count = 0
        samples.append((now, delta)); samples.removeAll { (now - $0.0) >= 60 }
        var s = Signal()
        s.keysPerMinute = Double(samples.reduce(0) { $0 + $1.1 })
        s.idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        s.screenAvailable = screenAvailable
        if p.contextDetection, let front = NSWorkspace.shared.frontmostApplication {
            s.category = Classifier.category(bundleID: front.bundleIdentifier ?? "", rules: p.appRules)
            if p.protectFullscreen { s.fullscreen = Self.isFullscreen(pid: front.processIdentifier) }
            if p.protectMicrophone { s.microphoneBusy = Self.inputDeviceRunning() }
        }
        if s.category != previousCategory { previousCategory = s.category; categorySince = now }
        s.categorySeconds = (now - categorySince)
        return (s, delta)
    }
    var screenAvailable: Bool {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return screenAwake && unlocked && !locked
    }
    private static func isFullscreen(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in windows where (w[kCGWindowOwnerPID as String] as? Int) == Int(pid) && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = w[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            // Screen-sized geometry is a conservative heuristic; no screen capture permission or pixel data.
            if NSScreen.screens.contains(where: { abs($0.frame.width - rect.width) < 3 && abs($0.frame.height - rect.height) < 3 }) { return true }
        }
        return false
    }
    private static func inputDeviceRunning() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return false }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}
