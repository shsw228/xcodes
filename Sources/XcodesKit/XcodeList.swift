import Foundation
import Path
import Version
import PromiseKit
import SwiftSoup
import struct XCModel.Xcode

/// Provides lists of available and installed Xcodes
public final class XcodeList {
    public init() {
        try? loadCachedAvailableXcodes()
    }

    public private(set) var availableXcodes: [Xcode] = []
    public private(set) var lastUpdated: Date?

    public var shouldUpdateBeforeListingVersions: Bool {
        return availableXcodes.isEmpty || (cacheAge ?? 0) > Self.maxCacheAge
    }

    public func shouldUpdateBeforeDownloading(version: Version) -> Bool {
        return availableXcodes.first(withVersion: version) == nil
    }

    public func update(dataSource: DataSource) -> Promise<[Xcode]> {
        switch dataSource {
        case .apple:
            return when(fulfilled: releasedXcodes(), prereleaseXcodes())
                .map { releasedXcodes, prereleaseXcodes in
                    // Starting with Xcode 11 beta 6, developer.apple.com/download and developer.apple.com/download/more both list some pre-release versions of Xcode.
                    // Previously pre-release versions only appeared on developer.apple.com/download.
                    // /download/more doesn't include build numbers, so we trust that if the version number and prerelease identifiers are the same that they're the same build.
                    // If an Xcode version is listed on both sites then prefer the one on /download because the build metadata is used to compare against installed Xcodes.
                    let xcodes = releasedXcodes.filter { releasedXcode in
                        prereleaseXcodes.contains { $0.version.isEquivalent(to: releasedXcode.version) } == false
                    } + prereleaseXcodes
                    self.availableXcodes = xcodes
                    self.lastUpdated = Date()
                    try? self.cacheAvailableXcodes(xcodes)
                    return xcodes
                }
        case .xcodeReleases:
            return xcodeReleases()
                .map { xcodes in
                    self.availableXcodes = xcodes
                    self.lastUpdated = Date()
                    try? self.cacheAvailableXcodes(xcodes)
                    return xcodes
                }
        }
    }
}

extension XcodeList {
    private static let maxCacheAge = TimeInterval(86400) // 24 hours

    private var cacheAge: TimeInterval? {
        guard let lastUpdated = lastUpdated else { return nil }
        return -lastUpdated.timeIntervalSinceNow
    }

    private func loadCachedAvailableXcodes() throws {
        guard let data = Current.files.contents(atPath: Path.cacheFile.string) else { return }
        let xcodes = try JSONDecoder().decode([Xcode].self, from: data)

        let attributes = try? Current.files.attributesOfItem(atPath: Path.cacheFile.string)
        let lastUpdated = attributes?[.modificationDate] as? Date

        self.availableXcodes = xcodes
        self.lastUpdated = lastUpdated
    }

    private func cacheAvailableXcodes(_ xcodes: [Xcode]) throws {
        let data = try JSONEncoder().encode(xcodes)
        try FileManager.default.createDirectory(at: Path.cacheFile.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Current.files.write(data, to: Path.cacheFile.url)
    }
}

extension XcodeList {
    // MARK: - Apple

    private func releasedXcodes() -> Promise<[Xcode]> {
        return firstly { () -> Promise<(data: Data, response: URLResponse)> in
            Current.network.dataTask(with: URLRequest.downloads)
        }
        .map { (data, response) -> [Xcode] in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .formatted(.downloadsDateModified)
            let downloads = try decoder.decode(Downloads.self, from: data)
            let xcodes = downloads
                .downloads
                .filter { $0.name.range(of: "^Xcode [0-9]", options: .regularExpression) != nil }
                .compactMap { download -> Xcode? in
                    let urlPrefix = URL(string: "https://download.developer.apple.com/")!
                    guard 
                        let xcodeFile = download.files.first(where: { $0.remotePath.hasSuffix("dmg") || $0.remotePath.hasSuffix("xip") }),
                        let version = Version(xcodeVersion: download.name)
                    else { return nil }

                    let url = urlPrefix.appendingPathComponent(xcodeFile.remotePath)
                    return Xcode(version: version, url: url, filename: String(xcodeFile.remotePath.suffix(fromLast: "/")), releaseDate: download.dateModified)
                }
            return xcodes
        }
    }

    private func prereleaseXcodes() -> Promise<[Xcode]> {
        return firstly { () -> Promise<(data: Data, response: URLResponse)> in
            Current.network.dataTask(with: URLRequest.download)
        }
        .map { (data, _) -> [Xcode] in
            try self.parsePrereleaseXcodes(from: data)
        }
    }

    func parsePrereleaseXcodes(from data: Data) throws -> [Xcode] {
        let body = String(data: data, encoding: .utf8)!
        let document = try SwiftSoup.parse(body)

        guard 
            let xcodeHeader = try document.select("h2:containsOwn(Xcode)").first(),
            let productBuildVersion = try xcodeHeader.parent()?.select("li:contains(Build)").text().replacingOccurrences(of: "Build", with: ""),
            let releaseDateString = try xcodeHeader.parent()?.select("li:contains(Released)").text().replacingOccurrences(of: "Released", with: ""),
            let version = Version(xcodeVersion: try xcodeHeader.text(), buildMetadataIdentifier: productBuildVersion),
            let path = try document.select(".direct-download[href*=xip]").first()?.attr("href"),
            let url = URL(string: "https://developer.apple.com" + path)
        else { return [] }

        let filename = String(path.suffix(fromLast: "/"))

        return [Xcode(version: version, url: url, filename: filename, releaseDate: DateFormatter.downloadsReleaseDate.date(from: releaseDateString))]
    }
}

extension XcodeList {
    // MARK: - XcodeReleases
    
    private func xcodeReleases() -> Promise<[Xcode]> {
        return firstly { () -> Promise<(data: Data, response: URLResponse)> in
            Current.network.dataTask(with: URLRequest(url: URL(string: "https://xcodereleases.com/data.json")!))
        }
        .map { (data, response) in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<non-utf8>"
            Current.logging.log("[xcodeReleases] status=\(statusCode) bytes=\(data.count)")
            Current.logging.log("[xcodeReleases] body-preview=\(preview.replacingOccurrences(of: "\n", with: "\\n"))")
            return try self.parseXcodeReleases(from: data)
        }
        .map(filterPrereleasesThatMatchReleaseBuildMetadataIdentifiers)
    }

    func parseXcodeReleases(from data: Data) throws -> [Xcode] {
        let decoder = JSONDecoder()
        let xcReleasesXcodes = try decoder.decode([TolerantXcodeReleasesXcode].self, from: data)
        return xcReleasesXcodes.compactMap { xcReleasesXcode in
            guard
                let downloadURL = xcReleasesXcode.links?.download?.url,
                let version = versionFromXcodeReleases(xcReleasesXcode)
            else { return nil }

            let releaseDate = Calendar(identifier: .gregorian).date(from: DateComponents(
                year: xcReleasesXcode.date.year,
                month: xcReleasesXcode.date.month,
                day: xcReleasesXcode.date.day
            ))

            return Xcode(
                version: version,
                url: downloadURL,
                filename: String(downloadURL.path.suffix(fromLast: "/")),
                releaseDate: releaseDate
            )
        }
    }

    private func versionFromXcodeReleases(_ xcode: TolerantXcodeReleasesXcode) -> Version? {
        var versionString = xcode.version.number ?? ""
        let components = versionString.components(separatedBy: ".")
        versionString += Array(repeating: ".0", count: max(0, 3 - components.count)).joined()

        switch xcode.version.release {
        case let .beta(beta):
            versionString += "-Beta"
            if beta > 1 {
                versionString += ".\(beta)"
            }
        case let .dp(dp):
            versionString += "-DP"
            if dp > 1 {
                versionString += ".\(dp)"
            }
        case .gm:
            versionString += "-GM"
        case let .gmSeed(gmSeed):
            versionString += "-GM.Seed"
            if gmSeed > 1 {
                versionString += ".\(gmSeed)"
            }
        case let .rc(rc):
            versionString += "-Release.Candidate"
            if rc > 1 {
                versionString += ".\(rc)"
            }
        case .release, .unknown:
            break
        }

        if let buildNumber = xcode.version.build {
            versionString += "+\(buildNumber)"
        }

        return Version(versionString)
    }
    
    /// Xcode Releases may have multiple releases with the same build metadata when a build doesn't change between candidate and final releases.
    /// For example, 12.3 RC and 12.3 are both build 12C33
    /// We don't care about that difference, so only keep the final release (GM or Release, in XCModel terms).
    /// The downside of this is that a user could technically have both releases installed, and so they won't both be shown in the list, but I think most users wouldn't do this.
    func filterPrereleasesThatMatchReleaseBuildMetadataIdentifiers(_ xcodes: [Xcode]) -> [Xcode] {
        // 1) De-dup same-build RC/beta vs final release.
        let releaseDeduplicated = Dictionary(grouping: xcodes, by: \.version.buildMetadataIdentifiers)
            .values
            .flatMap { group -> [Xcode] in
                if group.count <= 1 {
                    return group
                }

                let finalReleases = group.filter {
                    $0.version.prereleaseIdentifiers.isEmpty || $0.version.prereleaseIdentifiers == ["GM"]
                }
                return finalReleases.isEmpty ? group : finalReleases
            }

        // 2) De-dup distribution variants (Universal vs Apple Silicon) for the same version.
        return Dictionary(grouping: releaseDeduplicated, by: { $0.version.description })
            .values
            .map(selectPreferredDistribution)
    } 

    private func selectPreferredDistribution(_ group: [Xcode]) -> Xcode {
        guard group.count > 1 else { return group[0] }

        func rank(_ xcode: Xcode) -> Int {
            let name = xcode.filename.lowercased()
            let isAppleSilicon = name.contains("apple_silicon") || name.contains("apple-silicon")
            let isUniversal = name.contains("universal")

            #if arch(arm64)
            if isAppleSilicon { return 0 }
            if isUniversal { return 1 }
            #else
            if isUniversal { return 0 }
            if name.contains("x86_64") { return 1 }
            if isAppleSilicon { return 2 }
            #endif
            return 3
        }

        return group.min(by: { rank($0) < rank($1) }) ?? group[0]
    }
}

private struct TolerantXcodeReleasesXcode: Decodable {
    let version: TolerantXcodeReleasesVersion
    let date: TolerantXcodeReleasesDate
    let links: TolerantXcodeReleasesLinks?
}

private struct TolerantXcodeReleasesVersion: Decodable {
    let number: String?
    let build: String?
    let release: TolerantXcodeReleasesRelease
}

private struct TolerantXcodeReleasesDate: Decodable {
    let year: Int
    let month: Int
    let day: Int
}

private struct TolerantXcodeReleasesLinks: Decodable {
    let download: TolerantXcodeReleasesLink?
}

private struct TolerantXcodeReleasesLink: Decodable {
    let url: URL
}

private enum TolerantXcodeReleasesRelease: Decodable {
    case gm
    case gmSeed(Int)
    case rc(Int)
    case beta(Int)
    case dp(Int)
    case release
    case unknown

    private enum CodingKeys: String, CodingKey {
        case gm
        case gmSeed
        case rc
        case beta
        case dp
        case release
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            if let value = try container.decodeIfPresent(Bool.self, forKey: .gm), value {
                self = .gm
                return
            }
            if let value = Self.decodeInt(container, key: .gmSeed) {
                self = .gmSeed(value)
                return
            }
            if let value = Self.decodeInt(container, key: .rc) {
                self = .rc(value)
                return
            }
            if let value = Self.decodeInt(container, key: .beta) {
                self = .beta(value)
                return
            }
            if let value = Self.decodeInt(container, key: .dp) {
                self = .dp(value)
                return
            }
            if let value = try container.decodeIfPresent(Bool.self, forKey: .release), value {
                self = .release
                return
            }
        }
        self = .unknown
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}
