import Foundation

/// A newer release on GitHub. iOS does not let a sideloaded app install an IPA
/// itself, so "update" hands the IPA link to AltStore, which installs it over
/// this app and keeps its data (same bundle ID).
public struct UpdateInfo: Sendable, Equatable {
    public let version: String
    public let notes: String
    public let ipaURL: URL?
    public let pageURL: URL

    /// `altstore://install?url=…`, or nil when the release has no IPA.
    public var altStoreURL: URL? {
        guard let ipaURL else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = ipaURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "altstore://install?url=\(encoded)")
    }
}

public enum UpdateCheckResult: Sendable, Equatable {
    case available(UpdateInfo)
    case upToDate(latest: String)
    case failed
}

/// Compares dotted version numbers, ignoring a leading "v": 2.0.10 > 2.0.9.
public struct AppVersion: Comparable, Sendable {
    public let parts: [Int]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// Asks GitHub for the latest release of this (public) repo. Sends no
/// credentials and nothing about the user.
public struct UpdateChecker: Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/Reminiscence-Care/ReminiCare-Swift/releases/latest")!

    public let currentVersion: String
    public var http: HTTPSending

    public init(currentVersion: String = ReportEnvironment.current.appVersion, http: HTTPSending = URLSession(configuration: .ephemeral)) {
        self.currentVersion = currentVersion
        self.http = http
    }

    /// Only builds made by the release workflow ask on launch: xtool and local
    /// builds always say 2.0.0 and would otherwise always see an "update".
    public static var isReleaseBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ReminiCareChannel") as? String == "release"
    }

    public func check() async -> UpdateCheckResult {
        AppLog.shared.record(.update, .started, detail: "updateCheck")
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let prepared = request
        let http = http
        let watch = Stopwatch()
        do {
            let (data, response) = try await withTimeout(.seconds(15)) { try await http.send(prepared) }
            guard response.statusCode == 200, let latest = Self.parse(data) else {
                AppLog.shared.record(.update, .failed, durationMs: watch.milliseconds, statusCode: response.statusCode, detail: "updateFailed")
                return .failed
            }
            guard let remote = AppVersion(latest.version), let local = AppVersion(currentVersion), local < remote else {
                AppLog.shared.record(.update, .completed, durationMs: watch.milliseconds, detail: "updateNone")
                return .upToDate(latest: latest.version)
            }
            AppLog.shared.record(.update, .completed, durationMs: watch.milliseconds, detail: "updateAvailable")
            return .available(latest)
        } catch {
            AppLog.shared.record(.update, .failed, durationMs: watch.milliseconds, detail: "updateFailed")
            return .failed
        }
    }

    /// The release's version, notes, IPA asset and page; nil for drafts,
    /// prereleases or an unexpected body.
    static func parse(_ data: Data) -> UpdateInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, AppVersion(tag) != nil,
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)), page.scheme == "https" else {
            return nil
        }
        let assets = object["assets"] as? [[String: Any]] ?? []
        let ipa = assets.first { asset in
            guard let name = asset["name"] as? String else { return false }
            return name.hasPrefix("ReminiCare-") && name.hasSuffix(".ipa")
        }
        let ipaURL = (ipa?["browser_download_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = String((object["body"] as? String ?? "").prefix(1_000))
        return UpdateInfo(version: version, notes: notes, ipaURL: ipaURL, pageURL: page)
    }
}

/// When to ask on launch: at most once a day, and never again for a version
/// the user chose to skip.
public final class UpdatePreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let lastCheckKey = "update.lastCheck"
    private static let skippedKey = "update.skippedVersion"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var skippedVersion: String? { defaults.string(forKey: Self.skippedKey) }

    public func skip(_ version: String) { defaults.set(version, forKey: Self.skippedKey) }

    public func shouldCheck(now: Date = Date()) -> Bool {
        guard let last = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= 24 * 3600 || now < last
    }

    public func markChecked(now: Date = Date()) { defaults.set(now, forKey: Self.lastCheckKey) }

    /// The update to offer on launch, if any.
    public func launchOffer(_ result: UpdateCheckResult) -> UpdateInfo? {
        guard case .available(let info) = result, info.version != skippedVersion else { return nil }
        return info
    }
}
