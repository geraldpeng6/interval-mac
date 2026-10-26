import CryptoKit
import XCTest
@testable import Pause
@testable import PauseCore

/// Offline HTTP serving for the updater. Routes are installed per test and
/// every request is recorded so tests can prove which network access happened.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _route: ((URLRequest) -> Result<(Int, [String: String], Data), Error>)?
    private static var _requests: [String] = []

    static var route: ((URLRequest) -> Result<(Int, [String: String], Data), Error>)? {
        get { lock.lock(); defer { lock.unlock() }; return _route }
        set { lock.lock(); defer { lock.unlock() }; _route = newValue }
    }
    static var requests: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _requests }
        set { lock.lock(); defer { lock.unlock() }; _requests = newValue }
    }
    private static func record(_ url: String) { lock.lock(); _requests.append(url); lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url?.absoluteString { Self.record(url) }
        guard let route = Self.route else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        switch route(request) {
        case .success(let (status, headers, body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            // URLSession does not auto-follow a 3xx served by a custom protocol;
            // the protocol must report the redirect itself (as GitHub's CDN does).
            if (300..<400).contains(status), let location = headers["Location"], let target = URL(string: location) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Behavior contracts for the in-app updater, exercised against real files in
/// an isolated /tmp tree (real ad-hoc signatures, real ditto zips, real
/// Mach-O executables) and offline HTTP:
/// download never installs, the first “更新” click only asks for confirmation,
/// cancelling keeps the verified download, and only the confirmed second click
/// replaces the app — with every failure leaving the old version in place.
@MainActor final class UpdateEngineTests: XCTestCase {
    private var root: URL!
    private var appsDir: URL!
    private var updatesDir: URL!
    private var fixturesDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/interval-update-tests-\(UUID().uuidString)")
        appsDir = root.appendingPathComponent("apps")
        updatesDir = root.appendingPathComponent("updates")
        fixturesDir = root.appendingPathComponent("fixtures")
        for dir in [appsDir!, updatesDir!, fixturesDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        StubURLProtocol.route = nil
        StubURLProtocol.requests = []
    }

    override func tearDownWithError() throws {
        StubURLProtocol.route = nil
        StubURLProtocol.requests = []
        // Tests that simulate permission failures leave directories read-only.
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private struct Fixture {
        let app: URL
        let zip: URL
        let data: Data
        let sha256: String
        var size: Int { data.count }
    }

    private enum ExecKind { case systemBinary, x86Only, unsigned }

    /// Builds a genuine app bundle: real Mach-O executable, real Info.plist,
    /// real ad-hoc code signature (where requested), zipped with ditto exactly
    /// like the release pipeline does.
    private func buildFixture(version: String, appleVersion: String? = nil,
                              bundleID: String = "app.interval.rest", buildNumber: Int = 7,
                              minOS: String = "14.0", sign: Bool = true,
                              exec kind: ExecKind = .systemBinary,
                              tamperAfterSigning: Bool = false) throws -> Fixture {
        let home = fixturesDir.appendingPathComponent(UUID().uuidString)
        let app = home.appendingPathComponent("Interval.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = macos.appendingPathComponent("Interval")
        switch kind {
        case .systemBinary: try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        case .x86Only:
            try runTool("/usr/bin/lipo", ["-thin", "x86_64", "-output", executable.path, "/usr/bin/true"])
        case .unsigned:
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
            try runTool("/usr/bin/codesign", ["--remove-signature", executable.path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Interval",
            "CFBundleExecutable": "Interval",
            "CFBundleShortVersionString": appleVersion ?? (SemVer(version).map(\.appleVersion) ?? version),
            "CFBundleVersion": String(buildNumber),
            "IntervalFullVersion": version,
            "LSMinimumSystemVersion": minOS
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("resource".utf8).write(to: resources.appendingPathComponent("placeholder.txt"))
        if sign {
            try runTool("/usr/bin/codesign", ["--force", "--options", "runtime", "--sign", "-", app.path])
        }
        if tamperAfterSigning {
            try Data("injected".utf8).write(to: resources.appendingPathComponent("injected.txt"))
        }
        let zip = home.appendingPathComponent("Interval-\(version)-arm64.zip")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        let data = try Data(contentsOf: zip)
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Fixture(app: app, zip: zip, data: data, sha256: sha256)
    }

    @discardableResult
    private func installCurrentApp(version: String) throws -> URL {
        let fixture = try buildFixture(version: version)
        let destination = appsDir.appendingPathComponent("Interval.app")
        try FileManager.default.copyItem(at: fixture.app, to: destination)
        return destination
    }

    private func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "fixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(path) failed"])
        }
    }

    private func installedFullVersion(at app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        return plist?["IntervalFullVersion"] as? String
    }

    private func hasQuarantine(_ app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-p", "com.apple.quarantine", app.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 && !output.isEmpty
    }

    // MARK: HTTP + engine wiring

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func feedData(version: String, sha256: String, size: Int, assetName: String? = nil,
                          digest: String? = nil, state: String = "uploaded", draft: Bool = false,
                          downloadURL: String? = nil) throws -> Data {
        let name = assetName ?? "Interval-\(version)-arm64.zip"
        let release: [String: Any] = [
            "tag_name": "v\(version)",
            "draft": draft,
            "assets": [[
                "name": name,
                "size": size,
                "state": state,
                "digest": "sha256:\(digest ?? sha256)",
                "browser_download_url": downloadURL ?? "https://github.com/geraldpeng6/interval-mac/releases/download/v\(version)/\(name)"
            ] as [String: Any]]
        ]
        return try JSONSerialization.data(withJSONObject: [release])
    }

    private func serve(feed: Data, zip: Data? = nil) {
        StubURLProtocol.route = { request in
            guard let url = request.url else { return .failure(URLError(.badURL)) }
            // Match by host: GitHub's download URLs also contain "/releases" in
            // their path (…/releases/download/…), so path matching would serve
            // the feed where the ZIP belongs.
            if url.host == "api.example.test" { return .success((200, [:], feed)) }
            if let zip, url.absoluteString.contains(".zip") {
                return .success((200, [:], zip))
            }
            return .failure(URLError(.notConnectedToInternet))
        }
    }

    private func makeEngine(current: String, appURL: URL? = nil, directory: URL? = nil,
                            sessionActive: @escaping () -> Bool = { false },
                            present: @escaping (UpdatePlan) -> Bool = { _ in false },
                            relaunch: @escaping (URL) -> Void = { _ in }) -> UpdateEngine {
        UpdateEngine(
            feedURL: URL(string: "https://api.example.test/releases?per_page=100")!,
            directory: directory ?? updatesDir,
            currentVersion: current,
            expectedBundleID: "app.interval.rest",
            appURL: appURL,
            osVersion: (15, 0, 0),
            session: stubSession(),
            sessionActive: sessionActive,
            presentConfirmation: present,
            relaunch: relaunch)
    }

    @discardableResult
    private func awaitPhase(_ engine: UpdateEngine, _ label: String,
                            timeout: TimeInterval = 25,
                            matching: (UpdatePhase) -> Bool) async -> UpdatePhase {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if matching(engine.phase) { return engine.phase }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return engine.phase
    }

    private func isReady(_ phase: UpdatePhase) -> Bool {
        if case .ready = phase { return true }
        return false
    }

    private func settled(_ phase: UpdatePhase) -> Bool {
        switch phase {
        case .ready, .upToDate, .failed: return true
        default: return false
        }
    }

    private var zipPath: URL { updatesDir.appendingPathComponent("Interval-1.0.1-arm64.zip") }

    // MARK: Contract 1 — download only, never install

    func testDownloadAndReadyNeverTouchesInstalledApp() async throws {
        let current = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        var relaunched: [URL] = []
        let engine = makeEngine(current: "1.0.0-rc.2", appURL: current, relaunch: { relaunched.append($0) })
        engine.checkForUpdates()
        let phase = await awaitPhase(engine, "download settles", matching: settled)
        guard case .ready(let version) = phase else { return XCTFail("expected ready, got \(phase)") }
        XCTAssertEqual(version, "1.0.1")
        XCTAssertTrue(relaunched.isEmpty, "downloading must never relaunch or replace the app")
        XCTAssertEqual(try installedFullVersion(at: current), "1.0.0-rc.2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: appsDir.path), ["Interval.app"])
        // The verified package is on disk with its digest sidecar.
        XCTAssertEqual(try UpdateEngine.sha256Hex(file: zipPath), fixture.sha256)
        XCTAssertEqual(try String(contentsOf: zipPath.appendingPathExtension("sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), fixture.sha256)
    }

    // MARK: Contract 2 — the first click only asks for confirmation

    func testFirstClickOnlyAsksForConfirmation() async throws {
        let current = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        var presented: [UpdatePlan] = []
        var relaunched: [URL] = []
        let engine = makeEngine(current: "1.0.0-rc.2", appURL: current,
                                present: { presented.append($0); return false },
                                relaunch: { relaunched.append($0) })
        engine.checkForUpdates()
        _ = await awaitPhase(engine, "ready", matching: isReady)
        engine.updateButtonPressed() // first click
        guard presented.count == 1 else { return XCTFail("the first click must present the confirmation exactly once, got \(presented.count) after phase \(engine.phase)") }
        XCTAssertEqual(presented[0].current, "1.0.0-rc.2")
        XCTAssertEqual(presented[0].target, "1.0.1")
        XCTAssertTrue(relaunched.isEmpty)
        XCTAssertEqual(try installedFullVersion(at: current), "1.0.0-rc.2")
    }

    // MARK: Contract 3 — cancelling keeps the download and the ready state

    func testCancellingConfirmationKeepsDownloadAndReadyState() async throws {
        let current = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        var relaunched: [URL] = []
        let engine = makeEngine(current: "1.0.0-rc.2", appURL: current,
                                present: { _ in false }, // user pressed 取消 / Escape
                                relaunch: { relaunched.append($0) })
        engine.checkForUpdates()
        _ = await awaitPhase(engine, "ready", matching: isReady)
        engine.updateButtonPressed()
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipPath.path), "cancel must keep the verified download")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipPath.appendingPathExtension("sha256").path))
        if case .ready("1.0.1") = engine.phase {} else { XCTFail("ready state must survive cancel, got \(engine.phase)") }
        XCTAssertTrue(relaunched.isEmpty)
        XCTAssertEqual(try installedFullVersion(at: current), "1.0.0-rc.2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: appsDir.path), ["Interval.app"])
    }

    // MARK: Contract 4 — only the confirmed second click installs

    func testOnlyTheConfirmedSecondClickInstallsAndRelaunches() async throws {
        let current = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        var relaunched: [URL] = []
        let engine = makeEngine(current: "1.0.0-rc.2", appURL: current,
                                present: { _ in true }, // user clicked 更新 again in the dialog
                                relaunch: { relaunched.append($0) })
        engine.checkForUpdates()
        _ = await awaitPhase(engine, "ready", matching: isReady)
        // Simulate the quarantine mark a real URLSession download carries;
        // the installer must strip it from the verified bundle before swapping.
        try runTool("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000000;;Interval", zipPath.path])
        engine.updateButtonPressed()
        let phase = await awaitPhase(engine, "relaunch", matching: { _ in !relaunched.isEmpty })
        if case .installing("1.0.1") = phase {} else { XCTFail("expected installing, got \(phase)") }
        XCTAssertEqual(relaunched, [current])
        XCTAssertEqual(try installedFullVersion(at: current), "1.0.1", "the confirmed install must put the new version in place")
        XCTAssertFalse(hasQuarantine(current), "the replaced app must launch without a Gatekeeper block")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: appsDir.path), ["Interval.app"],
                       "staging and backup must be cleaned up")
    }

    // MARK: Install failure boundaries

    func testInstallFailureWhenFolderNotWritableKeepsOldVersionUsable() async throws {
        let current = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        var relaunched: [URL] = []
        let engine = makeEngine(current: "1.0.0-rc.2", appURL: current,
                                present: { _ in true }, relaunch: { relaunched.append($0) })
        engine.checkForUpdates()
        _ = await awaitPhase(engine, "ready", matching: isReady)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: appsDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appsDir.path) }
        engine.updateButtonPressed()
        let phase = await awaitPhase(engine, "recoverable failure", timeout: 15) { phase in
            if case .ready = phase { return self.engineHasNotice(engine) }
            return false
        }
        if case .ready = phase {} else { return XCTFail("install failure must return to ready, got \(phase)") }
        XCTAssertNotNil(engine.notice)
        XCTAssertTrue(engine.notice?.contains("未受影响") == true, "the message must say the old version is intact")
        XCTAssertTrue(relaunched.isEmpty)
        XCTAssertEqual(try installedFullVersion(at: current), "1.0.0-rc.2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipPath.path), "the download stays for a retry")
    }

    private func engineHasNotice(_ engine: UpdateEngine) -> Bool { engine.notice != nil }

    func testMidSwapFailureRollsBackToTheOldVersion() throws {
        let old = try installCurrentApp(version: "1.0.0-rc.2")
        let fresh = try buildFixture(version: "1.0.1")
        let stagedHome = root.appendingPathComponent("staging-src")
        try FileManager.default.createDirectory(at: stagedHome, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fresh.app, to: stagedHome.appendingPathComponent("Interval.app"))
        // The old app moves aside, but the new bundle cannot leave the read-only
        // staging directory — exactly the moment the swap must roll back.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stagedHome.path)
        XCTAssertThrowsError(try UpdateEngine.swap(staged: stagedHome.appendingPathComponent("Interval.app"), destination: old))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedHome.path)
        XCTAssertEqual(try installedFullVersion(at: old), "1.0.0-rc.2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: appsDir.path), ["Interval.app"])
    }

    func testSessionStartedWhileDialogWasOpenStillBlocksInstall() async throws {
        let current = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        var relaunched: [URL] = []
        var sessionNowActive = false
        let engine = makeEngine(current: "1.0.0-rc.2", appURL: current,
                                sessionActive: { sessionNowActive },
                                present: { _ in sessionNowActive = true; return true },
                                relaunch: { relaunched.append($0) })
        engine.checkForUpdates()
        _ = await awaitPhase(engine, "ready", matching: isReady)
        engine.updateButtonPressed() // confirm arrives while a session is running
        let phase = await awaitPhase(engine, "blocked", timeout: 10) { _ in self.engineHasNotice(engine) }
        if case .ready = phase {} else { XCTFail("expected to stay ready, got \(phase)") }
        XCTAssertEqual(engine.notice, UpdateError.sessionActive.localizedDescription)
        XCTAssertTrue(relaunched.isEmpty)
        XCTAssertEqual(try installedFullVersion(at: current), "1.0.0-rc.2")
    }

    func testRunningFromDiskImageRefusesToInstall() async throws {
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        let mountedApp = URL(fileURLWithPath: "/Volumes/Interval/Interval.app")
        var relaunched: [URL] = []
        let engine = makeEngine(current: "1.0.0-rc.2", appURL: mountedApp,
                                present: { _ in true }, relaunch: { relaunched.append($0) })
        engine.checkForUpdates()
        _ = await awaitPhase(engine, "ready", matching: isReady)
        engine.updateButtonPressed()
        _ = await awaitPhase(engine, "refused", timeout: 10) { _ in self.engineHasNotice(engine) }
        XCTAssertEqual(engine.notice, "安装失败：\(UpdateError.runningFromDiskImage.localizedDescription)当前版本未受影响，可重试。")
        XCTAssertTrue(relaunched.isEmpty)
    }

    // MARK: Verification rejections (download path)

    func testDigestMismatchIsRejectedAndCleanedUp() async throws {
        _ = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        let wrongDigest = String(repeating: "cd", count: 32)
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size, digest: wrongDigest),
              zip: fixture.data)
        let engine = makeEngine(current: "1.0.0-rc.2")
        engine.checkForUpdates()
        let phase = await awaitPhase(engine, "rejected", matching: settled)
        guard case .failed(_, let message) = phase else { return XCTFail("expected failure, got \(phase)") }
        XCTAssertTrue(message.contains("SHA-256"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updatesDir.path), [],
                       "a rejected download must leave nothing behind")
    }

    func testPackagesFailingBundleChecksAreRejected() async throws {
        _ = try installCurrentApp(version: "1.0.0-rc.2")
        struct Case { let name: String; let fixture: Fixture; let expectedFragment: String }
        let cases: [Case] = try [
            Case(name: "wrong bundle identity", fixture: buildFixture(version: "1.0.1", bundleID: "com.evil.example"),
                 expectedFragment: "身份"),
            Case(name: "full version inside package differs from release", fixture: buildFixture(version: "1.0.0"),
                 expectedFragment: "版本"),
            Case(name: "unsigned package", fixture: buildFixture(version: "1.0.1", sign: false, exec: .unsigned),
                 expectedFragment: "签名"),
            Case(name: "sealed then tampered package", fixture: buildFixture(version: "1.0.1", tamperAfterSigning: true),
                 expectedFragment: "签名"),
            Case(name: "x86-only package", fixture: buildFixture(version: "1.0.1", exec: .x86Only),
                 expectedFragment: "Apple Silicon"),
            Case(name: "minimum OS above current system", fixture: buildFixture(version: "1.0.1", minOS: "16.0"),
                 expectedFragment: "macOS 16.0")
        ]
        for testCase in cases {
            StubURLProtocol.requests = []
            let engine = makeEngine(current: "1.0.0-rc.2")
            serve(feed: try feedData(version: "1.0.1", sha256: testCase.fixture.sha256, size: testCase.fixture.size),
                  zip: testCase.fixture.data)
            engine.checkForUpdates()
            let phase = await awaitPhase(engine, testCase.name, matching: settled)
            guard case .failed(_, let message) = phase else { return XCTFail("\(testCase.name): expected failure, got \(phase)") }
            XCTAssertTrue(message.contains(testCase.expectedFragment), "\(testCase.name): \(message)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updatesDir.path), [], testCase.name)
        }
    }

    // MARK: Offline / scheduling / channel boundaries

    func testReadyStateSurvivesRestartAndInstallsWithoutNetwork() async throws {
        let current = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        let first = makeEngine(current: "1.0.0-rc.2")
        first.checkForUpdates()
        _ = await awaitPhase(first, "ready", matching: isReady)

        // App restart: a fresh engine over the same on-disk state, network down.
        StubURLProtocol.route = nil
        StubURLProtocol.requests = []
        var relaunched: [URL] = []
        let engine = makeEngine(current: "1.0.0-rc.2", appURL: current,
                                present: { _ in true }, relaunch: { relaunched.append($0) })
        if case .ready("1.0.1") = engine.phase {} else { XCTFail("ready must be restored offline, got \(engine.phase)") }
        XCTAssertEqual(StubURLProtocol.requests.count, 0, "restoring the ready state must not touch the network")
        engine.updateButtonPressed()
        _ = await awaitPhase(engine, "offline install", matching: { _ in !relaunched.isEmpty })
        XCTAssertEqual(try installedFullVersion(at: current), "1.0.1")
        XCTAssertEqual(StubURLProtocol.requests.count, 0, "installing a verified download needs no network")
    }

    func testCheckFailureKeepsReadyPackageAndStaysInstallable() async throws {
        let current = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        let engine = makeEngine(current: "1.0.0-rc.2", appURL: current)
        engine.checkForUpdates()
        _ = await awaitPhase(engine, "ready", matching: isReady)

        StubURLProtocol.route = { _ in .failure(URLError(.timedOut)) }
        engine.checkForUpdates()
        let phase = await awaitPhase(engine, "kept ready", timeout: 15) { _ in self.engineHasNotice(engine) }
        if case .ready("1.0.1") = phase {} else { XCTFail("a failed check must not invalidate the package, got \(phase)") }
        XCTAssertNotNil(engine.notice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipPath.path))
    }

    func testDownloadFailureCleansPartialFiles() async throws {
        _ = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        let feed = try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size)
        StubURLProtocol.route = { request in
            guard let url = request.url else { return .failure(URLError(.badURL)) }
            if url.host == "api.example.test" { return .success((200, [:], feed)) }
            return .failure(URLError(.timedOut))
        }
        let engine = makeEngine(current: "1.0.0-rc.2")
        engine.checkForUpdates()
        let phase = await awaitPhase(engine, "failed", matching: settled)
        if case .failed = phase {} else { return XCTFail("expected failure, got \(phase)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updatesDir.path), [],
                       "a failed download must clean its partial files")
    }

    func testStableCurrentDoesNotAdoptPrereleaseFromFeed() async throws {
        _ = try installCurrentApp(version: "1.0.0")
        let fixture = try buildFixture(version: "1.1.0-rc.1")
        serve(feed: try feedData(version: "1.1.0-rc.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        let engine = makeEngine(current: "1.0.0")
        engine.checkForUpdates()
        let phase = await awaitPhase(engine, "up to date", matching: settled)
        XCTAssertEqual(phase, .upToDate, "a stable build must not auto-downgrade to a prerelease")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updatesDir.path), [])
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "only the check ran; nothing was downloaded")
    }

    func testDownloadThroughRedirectIsStillDigestVerified() async throws {
        _ = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        let feed = try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size,
                                downloadURL: "https://github.com/geraldpeng6/interval-mac/releases/download/v1.0.1/redirect")
        StubURLProtocol.route = { request in
            guard let url = request.url else { return .failure(URLError(.badURL)) }
            if url.host == "api.example.test" { return .success((200, [:], feed)) }
            if url.path.contains("redirect") {
                return .success((302, ["Location": "https://objects.example.test/Interval-1.0.1-arm64.zip"], Data()))
            }
            if url.absoluteString.contains(".zip") { return .success((200, [:], fixture.data)) }
            return .failure(URLError(.notConnectedToInternet))
        }
        let engine = makeEngine(current: "1.0.0-rc.2")
        engine.checkForUpdates()
        let phase = await awaitPhase(engine, "ready via redirect", matching: settled)
        if case .ready("1.0.1") = phase {} else { XCTFail("expected ready after redirect, got \(phase)") }
    }

    func testAutoCheckFiresAfterLaunchDelayAndCanBeTurnedOff() async throws {
        _ = try installCurrentApp(version: "1.0.0-rc.2")
        let fixture = try buildFixture(version: "1.0.1")
        serve(feed: try feedData(version: "1.0.1", sha256: fixture.sha256, size: fixture.size), zip: fixture.data)
        let engine = makeEngine(current: "1.0.0-rc.2")
        engine.setAutoCheck(true)
        let phase = await awaitPhase(engine, "auto check fires", timeout: 20, matching: settled)
        if case .ready = phase {} else { return XCTFail("the scheduled check should find and fetch the update, got \(phase)") }
        engine.setAutoCheck(false)

        // With automatic checks off nothing may touch the network on its own:
        // the launch delay (8 s) must have been cancelled. A fresh, empty
        // updates directory keeps the previous test's package out of the way.
        StubURLProtocol.requests = []
        StubURLProtocol.route = nil
        let quietDirectory = root.appendingPathComponent("updates-quiet")
        try FileManager.default.createDirectory(at: quietDirectory, withIntermediateDirectories: true)
        let quiet = makeEngine(current: "1.0.0-rc.2", directory: quietDirectory)
        quiet.setAutoCheck(false)
        try await Task.sleep(nanoseconds: 9_500_000_000)
        XCTAssertEqual(StubURLProtocol.requests.count, 0, "auto check disabled must mean zero unattended network access")
        XCTAssertEqual(quiet.phase, .idle)
    }
}
