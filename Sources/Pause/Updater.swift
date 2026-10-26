import AppKit
import CryptoKit
import Foundation
import PauseCore
import Security
import SwiftUI

// MARK: - Phases and errors

/// End-to-end updater state; each phase maps to exactly one status line in UI and menu.
enum UpdatePhase: Equatable {
    case unavailable(String)
    case idle
    case checking
    case upToDate
    case downloading(version: String, progress: Double)
    case ready(version: String)
    case failed(version: String?, message: String)
    case installing(version: String)
}

/// What the confirmation dialog needs to show.
struct UpdatePlan: Equatable {
    let current: String
    let target: String
}

enum UpdateError: LocalizedError, Equatable {
    case http(Int)
    case invalidFeed
    case integrityMismatch
    case packageMissing
    case packageUnreadable
    case bundleIdentity(expected: String, found: String?)
    case versionMismatch(expected: String, found: String?)
    case appleVersionMismatch(expected: String, found: String?)
    case buildNumberInvalid
    case executableMissing
    case notArm64
    case minOSUnsupported(String)
    case signature(OSStatus)
    case runningFromDiskImage
    case notWritable
    case notAppBundle
    case sessionActive
    case toolFailed(String, Int32)
    case swapFailed(String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            code == 403 || code == 429
                ? "GitHub 暂时限制了请求频率，请稍后重试。"
                : "GitHub 返回 HTTP \(code)。"
        case .invalidFeed: "版本数据无法解析。"
        case .integrityMismatch: "安装包 SHA-256 校验不符，可能下载不完整或已损坏。"
        case .packageMissing: "已下载的安装包不存在，请重新检查更新。"
        case .packageUnreadable: "无法读取更新数据。"
        case .bundleIdentity(let expected, let found): "安装包身份不符（期望 \(expected)，实际 \(found ?? "无")），已拒绝。"
        case .versionMismatch(let expected, let found): "安装包版本不符（期望 \(expected)，实际 \(found ?? "无")）。"
        case .appleVersionMismatch(let expected, let found): "安装包 Apple 版本号不符（期望 \(expected)，实际 \(found ?? "无")）。"
        case .buildNumberInvalid: "安装包构建号无效。"
        case .executableMissing: "安装包缺少可执行文件。"
        case .notArm64: "安装包不包含 Apple Silicon（arm64）版本。"
        case .minOSUnsupported(let v): "新版本需要 macOS \(v) 或更高。"
        case .signature(let status): "安装包代码签名校验失败（\(status)），已拒绝。"
        case .runningFromDiskImage: "间歇正从磁盘映像或临时位置运行。请先把应用拖到「应用程序」文件夹，再更新。"
        case .notWritable: "没有权限写入应用所在文件夹。可到 GitHub 发布页手动下载，或调整文件夹权限后重试。"
        case .notAppBundle: "无法确定当前应用位置，请手动下载更新。"
        case .sessionActive: "请先完成或结束当前活动，再安装更新。"
        case .toolFailed(let tool, let code): "系统工具 \(tool) 执行失败（\(code)）。"
        case .swapFailed(let detail): detail
        }
    }
}

// MARK: - Engine

/// Owns the whole update flow: scheduled checks against this repository's public
/// GitHub Releases, background download, verification, and the confirmed install.
/// Downloading or being "ready" never touches the running app; the bundle is only
/// replaced inside `performInstall`, which runs after an explicit second click on
/// “更新” in the confirmation dialog. Cancelling that dialog keeps the verified
/// package and the ready state.
@MainActor final class UpdateEngine: ObservableObject {
    @Published private(set) var phase: UpdatePhase
    /// Secondary caption shown next to the status line: a recoverable install
    /// failure, or a check failure that did not invalidate a ready package.
    @Published private(set) var notice: String?
    @Published private(set) var lastCheck: Date?
    private(set) var autoCheckEnabled = false
    let currentVersionDisplay: String

    private let current: SemVer?
    private let feedURL: URL
    private let directory: URL
    private let expectedBundleID: String?
    private let appURL: URL?
    private let osVersion: (Int, Int, Int)
    private let session: URLSession
    private var sessionActive: () -> Bool
    private let presentConfirmation: @MainActor (UpdatePlan) -> Bool
    private let relaunch: @MainActor (URL) -> Void

    private var readyVersion: SemVer?
    private var autoTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var checkInFlight = false

    init(feedURL: URL,
         directory: URL,
         currentVersion: String?,
         expectedBundleID: String?,
         appURL: URL?,
         osVersion: (Int, Int, Int),
         session: URLSession,
         sessionActive: @escaping () -> Bool,
         presentConfirmation: @escaping (UpdatePlan) -> Bool,
         relaunch: @escaping (URL) -> Void) {
        self.feedURL = feedURL
        self.directory = directory
        self.expectedBundleID = expectedBundleID
        self.appURL = appURL
        self.osVersion = osVersion
        self.session = session
        self.sessionActive = sessionActive
        self.presentConfirmation = presentConfirmation
        self.relaunch = relaunch
        self.current = currentVersion.flatMap(SemVer.init)
        if let current {
            currentVersionDisplay = current.raw
            phase = .idle
        } else {
            currentVersionDisplay = "开发构建"
            phase = .unavailable("此构建没有版本信息，应用内更新不可用；可到 GitHub 发布页手动下载。")
        }
        restoreFromDisk()
    }

    /// Late-wired because the engine is created next to the app store, not by it.
    func attach(sessionActive: @escaping () -> Bool) { self.sessionActive = sessionActive }

    func setAutoCheck(_ enabled: Bool) {
        // Idempotent while already running: re-enabling must not restart the
        // schedule cadence (and hit GitHub again) on every window appearance.
        if enabled, autoCheckEnabled, autoTask != nil { return }
        autoCheckEnabled = enabled
        autoTask?.cancel(); autoTask = nil
        guard enabled else {
            // Turning auto updates off also stops any in-flight check/download.
            checkTask?.cancel(); checkTask = nil
            Self.purgePartials(in: directory)
            if case .downloading = phase { phase = .idle }
            else if case .checking = phase { phase = .idle }
            return
        }
        scheduleAutoChecks()
    }

    /// Manual “检查更新” entry; the scheduled path calls `runCheck` directly.
    func checkForUpdates() {
        guard current != nil, expectedBundleID != nil else { return }
        guard !checkInFlight, !isInstallUnderway else { return }
        checkTask = Task { [weak self] in await self?.runCheck() }
    }

    private var isInstallUnderway: Bool {
        if case .installing = phase { return true }
        return false
    }

    private func scheduleAutoChecks() {
        guard autoCheckEnabled, autoTask == nil else { return }
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                guard let self else { return }
                await self.runCheck()
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    // MARK: Checking

    private func runCheck() async {
        guard let current, expectedBundleID != nil, !checkInFlight, !isInstallUnderway else { return }
        checkInFlight = true
        defer { checkInFlight = false }
        notice = nil
        phase = .checking
        do {
            let data = try await fetchFeed()
            let releases = try UpdateFeed.parse(data)
            switch UpdateFeed.select(current: current, releases: releases) {
            case .upToDate:
                purgeZips(keeping: nil)
                readyVersion = nil
                phase = .upToDate
                lastCheck = Date()
            case .blockedRelease(let version):
                phase = .failed(version: version, message: "发现新版本 \(version)，但发布缺少可用的完整安装包（arm64 ZIP），可稍后重试或到 GitHub 发布页手动下载。")
                lastCheck = Date()
            case .candidate(let candidate):
                await prepare(candidate)
                lastCheck = Date()
            }
        } catch {
            guard !Task.isCancelled else { phase = .idle; return }
            let message = Self.describeCheckError(error)
            // A failed check does not invalidate an already verified package.
            if let readyVersion {
                notice = "检查更新失败：\(message)"
                phase = .ready(version: readyVersion.raw)
            } else {
                phase = .failed(version: nil, message: "检查更新失败：\(message)")
            }
        }
    }

    private func fetchFeed() async throws -> Data {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.setValue("Interval-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidFeed }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        return try await Self.collect(bytes: bytes, limit: 2_000_000)
    }

    private static func describeCheckError(_ error: Error) -> String {
        if let update = error as? UpdateError { return update.localizedDescription }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut { return "网络超时，请稍后重试。" }
            return urlError.localizedDescription
        }
        if error is DecodingError { return UpdateError.invalidFeed.localizedDescription }
        return error.localizedDescription
    }

    // MARK: Download + verify (never installs)

    private func prepare(_ candidate: UpdateCandidate) async {
        guard let bundleID = expectedBundleID else { return }
        let zipURL = directory.appendingPathComponent(candidate.zipName)
        // A previously verified download of the exact same version is reused as-is.
        if Self.readSidecar(zipURL) == candidate.sha256,
           (try? Self.sha256Hex(file: zipURL)) == candidate.sha256 {
            purgeZips(keeping: candidate.version)
            readyVersion = candidate.version
            phase = .ready(version: candidate.version.raw)
            return
        }
        phase = .downloading(version: candidate.version.raw, progress: 0)
        do {
            try await Self.download(session: session, candidate: candidate, to: zipURL) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading(candidate.version.raw, _) = self.phase else { return }
                    self.phase = .downloading(version: candidate.version.raw, progress: fraction)
                }
            }
            try await Self.verifyPackage(zip: zipURL, expected: candidate, bundleID: bundleID, osVersion: osVersion)
            try Self.writeSidecar(for: zipURL, sha256: candidate.sha256)
            purgeZips(keeping: candidate.version)
            readyVersion = candidate.version
            phase = .ready(version: candidate.version.raw)
        } catch {
            Self.removeZipArtifacts(zipURL)
            Self.purgePartials(in: directory)
            guard !Task.isCancelled else { phase = .idle; return }
            phase = .failed(version: candidate.version.raw, message: "更新包获取失败：\(error.localizedDescription)已清理，可重试。")
        }
    }

    /// Streams the ZIP to `<name>.zip.download` with progress, verifies digest and
    /// size against the GitHub API values, then renames it into place.
    nonisolated private static func download(session: URLSession, candidate: UpdateCandidate, to zipURL: URL,
                                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let partial = zipURL.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: partial)
        var request = URLRequest(url: candidate.zipURL)
        request.timeoutInterval = 30
        request.setValue("Interval-Updater", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: partial)
        var received = 0
        do {
            var buffer = Data(); buffer.reserveCapacity(256 * 1024)
            var lastReported = -1
            for try await byte in bytes {
                received += 1
                if received > candidate.size + 1_048_576 { throw UpdateError.integrityMismatch }
                buffer.append(byte)
                if buffer.count >= 256 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if candidate.size > 0, received % 131_072 == 0 {
                    let percent = Int(Double(received) / Double(candidate.size) * 100)
                    if percent != lastReported {
                        lastReported = percent
                        progress(min(1, Double(received) / Double(candidate.size)))
                    }
                }
            }
            try handle.write(contentsOf: buffer)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard received == candidate.size else { throw UpdateError.integrityMismatch }
        guard try sha256Hex(file: partial) == candidate.sha256 else { throw UpdateError.integrityMismatch }
        // All checks passed: the download becomes the canonical package.
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try FileManager.default.moveItem(at: partial, to: zipURL)
    }

    /// Unzips into a private staging area and runs the full bundle checks.
    /// Nothing here executes any part of the downloaded app.
    nonisolated private static func verifyPackage(zip: URL, expected: UpdateCandidate,
                                                  bundleID: String, osVersion: (Int, Int, Int)) async throws {
        guard try sha256Hex(file: zip) == expected.sha256 else { throw UpdateError.integrityMismatch }
        let staging = zip.deletingLastPathComponent().appendingPathComponent("staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        try verifyBundle(staging.appendingPathComponent("Interval.app"),
                         expectedVersion: expected.version, expectedBundleID: bundleID, osVersion: osVersion)
    }

    // MARK: Bundle verification (shared by download and install)

    /// Every check the downloaded bundle must pass before it may replace the app:
    /// readable plist, exact bundle identity, exact full + Apple version, sane
    /// build number, arm64 executable, minimum OS, and an intact code signature.
    nonisolated static func verifyBundle(_ app: URL, expectedVersion: SemVer, expectedBundleID: String,
                                         osVersion: (Int, Int, Int)) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { throw UpdateError.packageUnreadable }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, bundleID == expectedBundleID else {
            throw UpdateError.bundleIdentity(expected: expectedBundleID, found: plist["CFBundleIdentifier"] as? String)
        }
        guard let full = plist["IntervalFullVersion"] as? String, full == expectedVersion.raw else {
            throw UpdateError.versionMismatch(expected: expectedVersion.raw, found: plist["IntervalFullVersion"] as? String)
        }
        guard let apple = plist["CFBundleShortVersionString"] as? String, apple == expectedVersion.appleVersion else {
            throw UpdateError.appleVersionMismatch(expected: expectedVersion.appleVersion, found: plist["CFBundleShortVersionString"] as? String)
        }
        guard let build = plist["CFBundleVersion"] as? String, let buildNumber = Int(build), buildNumber >= 1 else {
            throw UpdateError.buildNumberInvalid
        }
        guard let execName = plist["CFBundleExecutable"] as? String, !execName.isEmpty, !execName.contains("/") else {
            throw UpdateError.executableMissing
        }
        let exec = app.appendingPathComponent("Contents/MacOS/\(execName)")
        guard let execData = try? Data(contentsOf: exec, options: .mappedIfSafe), !execData.isEmpty else {
            throw UpdateError.executableMissing
        }
        guard machOContainsArm64(execData) else { throw UpdateError.notArm64 }
        if let minimum = plist["LSMinimumSystemVersion"] as? String {
            guard osVersionTuple(minimum) <= osVersion else { throw UpdateError.minOSUnsupported(minimum) }
        }
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard createStatus == errSecSuccess, let code else { throw UpdateError.signature(createStatus) }
        let status = SecStaticCodeCheckValidity(code, [], nil)
        guard status == errSecSuccess else { throw UpdateError.signature(status) }
    }

    /// Accepts a thin arm64 Mach-O or a fat binary containing an arm64 slice.
    nonisolated static func machOContainsArm64(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        func le32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        func be32(_ offset: Int) -> UInt32 { le32(offset).byteSwapped }
        let cpuArm64: UInt32 = 0x0100_000C
        switch le32(0) {
        case 0xFEED_FACF: // 64-bit Mach-O, little-endian
            return le32(4) == cpuArm64
        case 0xBEBA_FECA, 0xBFBA_FECA: // FAT / FAT-64 headers are big-endian
            let entrySize = le32(0) == 0xBEBA_FECA ? 20 : 32
            let count = Int(be32(4))
            guard count > 0, count <= 32, data.count >= 8 + count * entrySize else { return false }
            for index in 0..<count where be32(8 + index * entrySize) == cpuArm64 { return true }
            return false
        default:
            return false
        }
    }

    nonisolated static func osVersionTuple(_ raw: String) -> (Int, Int, Int) {
        let parts = raw.split(separator: ".").compactMap { Int($0) }
        return (parts.count > 0 ? parts[0] : 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }

    @discardableResult
    nonisolated private static func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.toolFailed(path, -1) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.toolFailed(path, process.terminationStatus) }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    // MARK: Update button (confirm gate) and install

    /// The single action behind every “更新” button: it only asks for confirmation.
    /// Cancelling (or Escape / closing the dialog) keeps the verified download and
    /// the ready state untouched.
    func updateButtonPressed() {
        guard case .ready(let raw) = phase, let target = SemVer(raw), let bundleID = expectedBundleID else { return }
        guard !sessionActive() else {
            notice = UpdateError.sessionActive.localizedDescription
            return
        }
        let plan = UpdatePlan(current: currentVersionDisplay, target: raw)
        guard presentConfirmation(plan) else { return }
        Task { await performInstall(target: target, bundleID: bundleID) }
    }

    /// Runs only after the user clicked “更新” a second time in the confirmation
    /// dialog. Re-checks everything it relies on: session state, the package on
    /// disk, install conditions, and the full bundle verification.
    private func performInstall(target: SemVer, bundleID: String) async {
        guard case .ready = phase else { return }
        guard !sessionActive() else {
            notice = UpdateError.sessionActive.localizedDescription
            return
        }
        notice = nil
        phase = .installing(version: target.raw)
        let zipURL = directory.appendingPathComponent("Interval-\(target.raw)-arm64.zip")
        do {
            guard FileManager.default.fileExists(atPath: zipURL.path) else { throw UpdateError.packageMissing }
            guard let sidecar = Self.readSidecar(zipURL), try Self.sha256Hex(file: zipURL) == sidecar else {
                throw UpdateError.integrityMismatch
            }
            guard let appURL, appURL.pathExtension == "app" else { throw UpdateError.notAppBundle }
            guard !appURL.path.hasPrefix("/Volumes/") else { throw UpdateError.runningFromDiskImage }
            Self.cleanupInstallLeftovers(around: appURL)
            let parent = appURL.deletingLastPathComponent()
            let staging = parent.appendingPathComponent(".interval-update-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { throw UpdateError.notWritable }
            try await Self.unzipVerified(zip: zipURL, expectedVersion: target, expectedBundleID: bundleID,
                                         osVersion: osVersion, into: staging)
            let newApp = staging.appendingPathComponent("Interval.app")
            // Verification passed: remove the quarantine marks this download
            // carried, so Gatekeeper does not kill the replaced ad-hoc app at
            // relaunch. Manual DMG downloads keep their normal Gatekeeper flow.
            try Self.runTool("/usr/bin/xattr", ["-cr", newApp.path])
            try Self.swap(staged: newApp, destination: appURL)
            relaunch(appURL)
        } catch {
            notice = "安装失败：\(error.localizedDescription)当前版本未受影响，可重试。"
            phase = .ready(version: target.raw)
        }
    }

    /// Fresh unzip + full verification near the install location (same volume).
    nonisolated private static func unzipVerified(zip: URL, expectedVersion: SemVer, expectedBundleID: String,
                                                  osVersion: (Int, Int, Int), into staging: URL) async throws {
        try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        try verifyBundle(staging.appendingPathComponent("Interval.app"),
                         expectedVersion: expectedVersion, expectedBundleID: expectedBundleID, osVersion: osVersion)
    }

    /// Replaces the app at `destination` with the verified bundle at `staged`.
    /// The old version is moved aside first and restored if the swap fails.
    nonisolated static func swap(staged: URL, destination: URL) throws {
        let manager = FileManager.default
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).interval-old-\(UUID().uuidString)")
        try manager.moveItem(at: destination, to: backup)
        do {
            try manager.moveItem(at: staged, to: destination)
        } catch {
            do { try manager.moveItem(at: backup, to: destination) }
            catch { throw UpdateError.swapFailed("无法恢复原版本，已保留在 \(backup.path)，请手动放回。") }
            throw error
        }
        try? manager.removeItem(at: backup)
    }

    /// Removes staging dirs and stale backups from previous installs. A backup is
    /// only deleted while the app is in place — otherwise it may be the only copy.
    nonisolated private static func cleanupInstallLeftovers(around appURL: URL) {
        let manager = FileManager.default
        let parent = appURL.deletingLastPathComponent()
        guard let entries = try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { return }
        let appPresent = manager.fileExists(atPath: appURL.path)
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".interval-update-") { try? manager.removeItem(at: entry) }
            else if appPresent, name.hasPrefix(".\(appURL.lastPathComponent).interval-old-") { try? manager.removeItem(at: entry) }
        }
    }

    // MARK: Local package bookkeeping

    /// Loads a previously verified package: the newest ZIP whose sidecar digest
    /// still matches its contents. Partial downloads and stale staging dirs are
    /// removed; older or unreadable packages are discarded.
    private func restoreFromDisk() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Self.purgePartials(in: directory)
        guard let contents = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var newest: (SemVer, URL)?
        for entry in contents where entry.lastPathComponent.hasPrefix("Interval-") && entry.lastPathComponent.hasSuffix("-arm64.zip") {
            let middle = String(entry.lastPathComponent.dropFirst("Interval-".count).dropLast("-arm64.zip".count))
            guard let version = SemVer(middle), let current, version > current else {
                Self.removeZipArtifacts(entry)
                continue
            }
            guard let digest = Self.readSidecar(entry), (try? Self.sha256Hex(file: entry)) == digest else {
                Self.removeZipArtifacts(entry)
                continue
            }
            if newest.map({ version > $0.0 }) ?? true { newest = (version, entry) }
        }
        guard let (version, url) = newest else { return }
        for entry in contents where entry.lastPathComponent.hasPrefix("Interval-") && entry.lastPathComponent.hasSuffix("-arm64.zip") && entry != url {
            Self.removeZipArtifacts(entry)
        }
        readyVersion = version
        phase = .ready(version: version.raw)
    }

    /// Deletes zips other than the kept version (and their sidecars).
    private func purgeZips(keeping kept: SemVer?) {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in contents where entry.lastPathComponent.hasPrefix("Interval-") && entry.lastPathComponent.hasSuffix("-arm64.zip") {
            let middle = String(entry.lastPathComponent.dropFirst("Interval-".count).dropLast("-arm64.zip".count))
            if let kept, middle == kept.raw { continue }
            Self.removeZipArtifacts(entry)
        }
    }

    nonisolated private static func purgePartials(in directory: URL) {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in contents {
            let name = entry.lastPathComponent
            if name.hasSuffix(".download") || name.hasPrefix("staging-") { try? manager.removeItem(at: entry) }
        }
    }

    nonisolated static func readSidecar(_ zipURL: URL) -> String? {
        guard let text = try? String(contentsOf: zipURL.appendingPathExtension("sha256"), encoding: .utf8) else { return nil }
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return hex
    }

    nonisolated private static func writeSidecar(for zipURL: URL, sha256: String) throws {
        try "\(sha256)\n".data(using: .utf8)?.write(to: zipURL.appendingPathExtension("sha256"), options: .atomic)
    }

    nonisolated private static func removeZipArtifacts(_ zipURL: URL) {
        try? FileManager.default.removeItem(at: zipURL)
        try? FileManager.default.removeItem(at: zipURL.appendingPathExtension("sha256"))
    }

    nonisolated static func sha256Hex(file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func collect(bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw UpdateError.invalidFeed }
        }
        return data
    }
}

// MARK: - UI-facing summaries

extension UpdateEngine {
    /// One status line shared verbatim by the window and the menu bar: version
    /// numbers, download progress and error explanations live here, never on a
    /// button.
    var statusText: String {
        switch phase {
        case .unavailable(let reason): return reason
        case .idle: return autoCheckEnabled ? "未检查更新" : "自动检查已关闭，可手动检查更新"
        case .checking: return "正在检查更新…"
        case .upToDate: return "已是最新版本"
        case .downloading(let version, let progress): return "发现新版本 \(version) · 已下载 \(Int(progress * 100))%"
        case .ready(let version): return "新版本 \(version) 已下载并校验，可以更新"
        case .failed(_, let message): return message
        case .installing(let version): return "正在安装 \(version)…"
        }
    }
    var canCheck: Bool {
        if case .unavailable = phase { return false }
        return true
    }
    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }
    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

// MARK: - Production wiring

extension UpdateEngine {
    /// The real configuration: this repository's public GitHub Releases, the
    /// user's Application Support folder, and the packaged app's own metadata.
    static func production() -> UpdateEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 600
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return UpdateEngine(
            feedURL: URL(string: "https://api.github.com/repos/geraldpeng6/interval-mac/releases?per_page=100")!,
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Interval/updates"),
            currentVersion: info["IntervalFullVersion"] as? String,
            expectedBundleID: Bundle.main.bundleIdentifier,
            appURL: Bundle.main.bundleURL,
            osVersion: (os.majorVersion, os.minorVersion, os.patchVersion),
            session: URLSession(configuration: configuration),
            sessionActive: { false },
            presentConfirmation: UpdateDialogs.present,
            relaunch: UpdateRelauncher.relaunchAndTerminate
        )
    }
}

enum UpdateDialogs {
    /// The install confirmation. “取消” carries the default focus (Return) and
    /// Escape cancels; “更新” only acts on an explicit click.
    @MainActor static func present(_ plan: UpdatePlan) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "安装更新？"
        alert.informativeText = "将从 \(plan.current) 更新到 \(plan.target)。安装后，间歇会重新启动。"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "取消")
        // Default focus on 取消: Return activates it; 更新 has no key equivalent.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { (event: NSEvent) -> NSEvent? in
            if event.keyCode == 53 { // Escape cancels, never installs
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
                return nil
            }
            return event
        }
        let response = alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        return response == .alertFirstButtonReturn
    }
}

enum UpdateRelauncher {
    /// Spawns a detached helper that waits for this process to exit and then
    /// opens the replaced app, and terminates normally so local data is saved.
    @MainActor static func relaunchAndTerminate(_ appURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let escaped = appURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "for i in $(seq 1 600); do ps -p \(pid) >/dev/null 2>&1 || break; sleep 0.1; done; open '\(escaped)'"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        // Terminate only if the helper actually launched; otherwise keep running
        // from memory — the new version is on disk and opens on the next launch.
        guard (try? helper.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
