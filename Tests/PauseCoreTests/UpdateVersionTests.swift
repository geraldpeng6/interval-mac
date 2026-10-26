import XCTest
@testable import PauseCore

/// Version parsing, precedence and release selection: the rules that decide
/// which GitHub release (if any) an installed build may update to.
final class UpdateVersionTests: XCTestCase {
    // MARK: SemVer parsing

    func testStrictSemverAcceptsPipelineForms() {
        for raw in ["1.0.0", "1.0.0-rc.2", "1.0.0-rc.10", "0.0.1", "2.13.4", "1.0.0-rc.2+build.5", "1.0.0-alpha.1.beta", "1.0.0-20261026"] {
            XCTAssertNotNil(SemVer(raw), raw)
        }
        XCTAssertEqual(SemVer("1.0.0-rc.2")?.appleVersion, "1.0.0")
        XCTAssertEqual(SemVer("1.2.3")?.appleVersion, "1.2.3")
        XCTAssertTrue(SemVer("1.0.0-rc.2")!.isPrerelease)
        XCTAssertFalse(SemVer("1.0.0")!.isPrerelease)
    }

    func testStrictSemverRejectsInvalidAndLeadingZeroForms() {
        for raw in ["", "1.0", "1.0.0.0", "01.0.0", "1.0.0-rc.02", "1.0.0-", "1.0.0-rc..2", "1.0.0+", "1.0.0+b!", "abc", "1.0.0-rc.2+", "1..0.0", "v1.0.0", "1.0.0-1234567890"] {
            XCTAssertNil(SemVer(raw), raw)
        }
    }

    // MARK: Precedence

    func testPrereleaseNumbersCompareNumericallyNotLexically() {
        XCTAssertLessThan(SemVer("1.0.0-rc.2")!, SemVer("1.0.0-rc.10")!)
        XCTAssertGreaterThan(SemVer("1.0.0-rc.10")!, SemVer("1.0.0-rc.9")!)
        XCTAssertLessThan(SemVer("1.0.0-rc.2")!, SemVer("1.0.0-rc.2.1")!)
    }

    func testPrereleaseSortsBelowStableAndCoreFieldsDominate() {
        XCTAssertLessThan(SemVer("1.0.0-rc.99")!, SemVer("1.0.0")!)
        XCTAssertLessThan(SemVer("1.0.0")!, SemVer("1.0.1")!)
        XCTAssertLessThan(SemVer("1.0.0-alpha")!, SemVer("1.0.0-beta")!)
        XCTAssertLessThan(SemVer("1.0.0-1")!, SemVer("1.0.0-alpha")!) // numeric < alphanumeric
        XCTAssertLessThan(SemVer("0.9.9")!, SemVer("1.0.0-rc.1")!)
    }

    func testBuildMetadataDoesNotAffectPrecedence() throws {
        // Equal precedence, different versions: differing build metadata must not
        // make either side "newer", and neither sorts below the other.
        let a = try XCTUnwrap(SemVer("1.0.0+build.7"))
        let b = try XCTUnwrap(SemVer("1.0.0+build.9"))
        XCTAssertFalse(a < b)
        XCTAssertFalse(b < a)
        XCTAssertFalse(a < SemVer("1.0.0")!)
        XCTAssertFalse(SemVer("1.0.0")! < a)
    }

    // MARK: GitHub digest parsing

    func testDigestFieldParsingAcceptsOnlyWellFormedSHA256() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(UpdateFeed.digestHex("sha256:\(hex)"), hex)
        XCTAssertEqual(UpdateFeed.digestHex("sha256:\(hex.uppercased())"), hex)
        XCTAssertNil(UpdateFeed.digestHex("md5:\(hex)"))
        XCTAssertNil(UpdateFeed.digestHex("sha256:abc"))
        XCTAssertNil(UpdateFeed.digestHex("sha256:\(hex)zz"))
        XCTAssertNil(UpdateFeed.digestHex(nil))
    }

    // MARK: Release payload parsing

    private func payload(version: String, zipName: String? = nil, digest: String? = nil, state: String = "uploaded",
                         size: Int? = 742_766, draft: Bool = false, tag: String? = nil) throws -> Data {
        let hex = digest ?? String(repeating: "ab", count: 32)
        let name = zipName ?? "Interval-\(version)-arm64.zip"
        let release: [String: Any] = [
            "tag_name": tag ?? "v\(version)",
            "draft": draft,
            "assets": [[
                "name": name,
                "size": size as Any,
                "state": state,
                "digest": "sha256:\(hex)",
                "browser_download_url": "https://github.com/geraldpeng6/interval-mac/releases/download/v\(version)/\(name)"
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: [release])
    }

    func testParseReadsRealisticReleasePayloadAndToleratesMissingOptionals() throws {
        let data = try payload(version: "1.0.0-rc.3")
        let releases = try UpdateFeed.parse(data)
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].tag, "v1.0.0-rc.3")
        XCTAssertEqual(releases[0].version, SemVer("1.0.0-rc.3"))
        XCTAssertEqual(releases[0].assets.count, 1)
        XCTAssertEqual(releases[0].assets[0].sha256, String(repeating: "ab", count: 32))
        XCTAssertEqual(releases[0].assets[0].name, "Interval-1.0.0-rc.3-arm64.zip")

        let sparse = #"[{"tag_name":"not-a-version"}]"#
        let parsed = try UpdateFeed.parse(Data(sparse.utf8))
        XCTAssertNil(parsed[0].version) // unusable tag, not a crash
        XCTAssertTrue(parsed[0].assets.isEmpty)
        XCTAssertThrowsError(try UpdateFeed.parse(Data("broken".utf8)))
        XCTAssertThrowsError(try UpdateFeed.parse(Data(#"{"message":"Moved"}"#.utf8))) // not an array
    }

    // MARK: Selection

    private func select(_ current: String, _ payloads: [Data]) throws -> UpdateChoice {
        let releases = try payloads.map { try UpdateFeed.parse($0) }.flatMap { $0 }
        return UpdateFeed.select(current: try XCTUnwrap(SemVer(current)), releases: releases)
    }

    func testSelectionPicksNewestCompatibleAndSkipsOlder() throws {
        let choice = try select("1.0.0-rc.2", [
            try payload(version: "1.0.0-rc.1"), // older
            try payload(version: "1.0.0-rc.3"),
            try payload(version: "1.0.0")        // stable beats rc.3
        ])
        guard case .candidate(let candidate) = choice else { return XCTFail("expected candidate, got \(choice)") }
        XCTAssertEqual(candidate.version, SemVer("1.0.0"))
        XCTAssertEqual(candidate.zipName, "Interval-1.0.0-arm64.zip")
    }

    func testSelectionIsUpToDateWhenNothingNewer() throws {
        XCTAssertEqual(try select("1.0.0-rc.2", [try payload(version: "1.0.0-rc.2"), try payload(version: "1.0.0-rc.1")]), .upToDate)
        XCTAssertEqual(try select("1.0.0", []), .upToDate)
    }

    func testStableCurrentNeverAdoptsPrerelease() throws {
        XCTAssertEqual(try select("1.0.0", [try payload(version: "1.1.0-rc.1")]), .upToDate)
        // Same feed, but a newer stable release exists: the stable wins.
        let choice = try select("1.0.0", [try payload(version: "1.1.0-rc.1"), try payload(version: "1.0.1")])
        guard case .candidate(let candidate) = choice else { return XCTFail("expected candidate, got \(choice)") }
        XCTAssertEqual(candidate.version, SemVer("1.0.1"))
    }

    func testDraftReleasesAndNonVTagsAreIgnored() throws {
        XCTAssertEqual(try select("1.0.0", [try payload(version: "1.1.0", draft: true)]), .upToDate)
        XCTAssertEqual(try select("1.0.0", [try payload(version: "1.1.0", tag: "build-42")]), .upToDate)
    }

    func testReleaseWithoutUsableFullAssetIsBlockedNotUpToDate() throws {
        let cases: [(String, String, Data)] = [
            ("missing zip asset", "1.0.1", try payload(version: "1.0.1", zipName: "Interval-1.0.1-arm64.dmg")),
            ("asset name does not match its version", "1.0.1", try payload(version: "1.0.1", zipName: "Interval-1.0.1-rc.0-arm64.zip")),
            ("still uploading", "1.0.1", try payload(version: "1.0.1", state: "starter")),
            ("no digest", "1.0.1", try payload(version: "1.0.1", digest: "sha256:short")),
            ("empty file", "1.0.1", try payload(version: "1.0.1", size: 0))
        ]
        for (name, expected, data) in cases {
            let choice = try select("1.0.0", [data])
            guard case .blockedRelease(let version) = choice else { return XCTFail("\(name): expected blockedRelease, got \(choice)") }
            XCTAssertEqual(version, expected, name)
        }
    }
}
