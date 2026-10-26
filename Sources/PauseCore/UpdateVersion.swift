import Foundation

/// Strict semver (MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]) with the same rules
/// `scripts/version.sh` enforces on release tags: numeric identifiers carry no
/// leading zeros; build metadata is allowed but ignored for precedence.
/// `raw` keeps the exact spelling because release asset names embed it verbatim.
/// Numeric identifiers are bounded to 9 digits so precedence never overflows;
/// pipeline versions are far below that.
public struct SemVer: Equatable, Comparable, Sendable {
    public let raw: String
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]?
    public let build: String?
    public var isPrerelease: Bool { prerelease != nil }
    /// Numeric Apple version (CFBundleShortVersionString) for this full version.
    public var appleVersion: String { "\(major).\(minor).\(patch)" }

    public init?(_ raw: String) {
        var core = raw
        var build: String?
        if let plus = raw.firstIndex(of: "+") {
            let meta = String(raw[raw.index(after: plus)...])
            // Build metadata is dot-separated alphanumerics; the dots themselves
            // are separators, so each segment is validated, not the whole string.
            let parts = meta.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !meta.isEmpty, parts.allSatisfy(Self.isBuildMeta) else { return nil }
            build = meta
            core = String(raw[raw.startIndex..<plus])
        }
        var prerelease: [String]?
        if let dash = core.firstIndex(of: "-") {
            let pre = String(core[core.index(after: dash)...])
            let ids = pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, ids.allSatisfy(Self.isIdentifier) else { return nil }
            prerelease = ids
            core = String(core[core.startIndex..<dash])
        }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard numbers.count == 3, numbers.allSatisfy({ Self.isNumeric($0) }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else { return nil }
        self.raw = raw; self.major = major; self.minor = minor; self.patch = patch
        self.prerelease = prerelease; self.build = build
    }

    /// [0-9A-Za-z-]+ dot-separated, at least one character.
    private static func isBuildMeta(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isSemverChar } }
    /// Identifier rules: [0-9A-Za-z-]+; a purely numeric one must not have
    /// leading zeros and stays within Int range (see type comment).
    private static func isIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty, s.allSatisfy({ $0.isSemverChar }) else { return false }
        return !s.isAllDigits || (s.count <= 9 && (s == "0" || !s.hasPrefix("0")))
    }
    /// Core component: plain decimal number, no leading zeros (except "0").
    private static func isNumeric(_ s: String) -> Bool {
        guard !s.isEmpty, s.isAllDigits, s.count <= 9 else { return false }
        return s == "0" || !s.hasPrefix("0")
    }

    /// Semver 2.0 precedence: numeric core fields, then prerelease identifiers
    /// (absent > present, numeric < alphanumeric, numeric compared numerically,
    /// alphanumeric ASCII-lexically, fewer identifiers = lower).
    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        guard let a = lhs.prerelease, let b = rhs.prerelease else {
            return lhs.prerelease != nil && rhs.prerelease == nil
        }
        for (x, y) in zip(a, b) {
            if x == y { continue }
            switch (x.isAllDigits, y.isAllDigits) {
            case (true, true): return Int(x)! < Int(y)!
            case (true, false): return true
            case (false, true): return false
            case (false, false): return x < y
            }
        }
        return a.count < b.count
    }
}

extension String {
    var isAllDigits: Bool { !isEmpty && allSatisfy { ("0"..."9").contains($0) } }
}
extension Character {
    var isSemverChar: Bool {
        ("0"..."9").contains(self) || ("a"..."z").contains(self) || ("A"..."Z").contains(self) || self == "-"
    }
}

/// One release asset as published on GitHub Releases.
public struct UpdateAsset: Equatable, Sendable {
    public let name: String
    public let size: Int?
    public let state: String?
    /// Lowercase hex SHA-256 from GitHub's server-computed `digest` field, if usable.
    public let sha256: String?
    public let downloadURL: URL?
    public init(name: String, size: Int?, state: String?, sha256: String?, downloadURL: URL?) {
        self.name = name; self.size = size; self.state = state; self.sha256 = sha256; self.downloadURL = downloadURL
    }
}

/// One GitHub release, with the tag parsed as semver when possible.
public struct UpdateRelease: Equatable, Sendable {
    public let tag: String
    public let version: SemVer?
    public let draft: Bool
    public let assets: [UpdateAsset]
    public init(tag: String, draft: Bool, assets: [UpdateAsset]) {
        self.tag = tag; self.draft = draft; self.assets = assets
        self.version = tag.hasPrefix("v") ? SemVer(String(tag.dropFirst())) : nil
    }
}

/// A release chosen as the update target, bound to one exact ZIP asset.
public struct UpdateCandidate: Equatable, Sendable {
    public let version: SemVer
    public let zipURL: URL
    public let size: Int
    public let sha256: String
    public var zipName: String { "Interval-\(version.raw)-arm64.zip" }
    public init(version: SemVer, zipURL: URL, size: Int, sha256: String) {
        self.version = version; self.zipURL = zipURL; self.size = size; self.sha256 = sha256
    }
}

public enum UpdateChoice: Equatable, Sendable {
    case upToDate
    case candidate(UpdateCandidate)
    /// A newer version exists on the accepted channel but ships no usable full asset.
    case blockedRelease(version: String)
}

/// Parses GitHub's public releases payload and picks the update target.
/// The pipeline publishes ZIP assets named `Interval-{full version}-arm64.zip`
/// with GitHub-computed SHA-256 digests; anything else is not updatable.
public enum UpdateFeed {
    public static func parse(_ data: Data) throws -> [UpdateRelease] {
        struct DTO: Decodable {
            struct AssetDTO: Decodable {
                let name: String?
                let size: Int?
                let state: String?
                let digest: String?
                let browser_download_url: String?
            }
            let tag_name: String?
            let draft: Bool?
            let assets: [AssetDTO]?
        }
        let dtos = try JSONDecoder().decode([DTO].self, from: data)
        return dtos.map { dto in
            UpdateRelease(
                tag: dto.tag_name ?? "",
                draft: dto.draft ?? false,
                assets: (dto.assets ?? []).compactMap { asset in
                    guard let name = asset.name else { return nil }
                    return UpdateAsset(
                        name: name,
                        size: asset.size,
                        state: asset.state,
                        sha256: Self.digestHex(asset.digest),
                        downloadURL: asset.browser_download_url.flatMap(URL.init(string:))
                    )
                }
            )
        }
    }

    /// "sha256:<64 hex>" (any case) → lowercase hex; anything else is unusable.
    static func digestHex(_ raw: String?) -> String? {
        guard let raw, raw.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = String(raw.dropFirst("sha256:".count)).lowercased()
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return hex
    }

    /// Picks the newest strictly-greater version. A stable current version never
    /// automatically adopts a prerelease; a prerelease current version may move
    /// to newer prereleases or to stable.
    public static func select(current: SemVer, releases: [UpdateRelease]) -> UpdateChoice {
        var best: UpdateCandidate?
        var blocked: SemVer?
        for release in releases {
            guard !release.draft, let version = release.version, version > current else { continue }
            if !current.isPrerelease && version.isPrerelease { continue }
            guard let candidate = usableCandidate(version: version, assets: release.assets) else {
                if blocked.map({ version > $0 }) ?? true { blocked = version }
                continue
            }
            if best.map({ version > $0.version }) ?? true { best = candidate }
        }
        if let best { return .candidate(best) }
        if let blocked { return .blockedRelease(version: blocked.raw) }
        return .upToDate
    }

    /// Only the exact pipeline asset counts: full-version name, finished upload,
    /// known size, server-computed digest, HTTPS download URL.
    static func usableCandidate(version: SemVer, assets: [UpdateAsset]) -> UpdateCandidate? {
        let name = "Interval-\(version.raw)-arm64.zip"
        guard let asset = assets.first(where: { $0.name == name }),
              asset.state == "uploaded",
              let size = asset.size, size > 0,
              let sha256 = asset.sha256,
              let url = asset.downloadURL, url.scheme == "https"
        else { return nil }
        return UpdateCandidate(version: version, zipURL: url, size: size, sha256: sha256)
    }
}
