import XCTest
import Version
@testable import XcodesKit

final class XcodeReleasesParsingTests: XCTestCase {
    func test_FilterPrereleases_DeduplicatesDistributionByHostArchitecture() throws {
        let xcodes: [Xcode] = [
            Xcode(
                version: Version("26.3.0-Release.Candidate+17C519")!,
                url: URL(string: "https://example.com/Xcode_26.3_Release_Candidate_Apple_silicon.xip")!,
                filename: "Xcode_26.3_Release_Candidate_Apple_silicon.xip",
                releaseDate: nil
            ),
            Xcode(
                version: Version("26.3.0-Release.Candidate+17C519")!,
                url: URL(string: "https://example.com/Xcode_26.3_Release_Candidate_Universal.xip")!,
                filename: "Xcode_26.3_Release_Candidate_Universal.xip",
                releaseDate: nil
            )
        ]

        let filtered = XcodeList().filterPrereleasesThatMatchReleaseBuildMetadataIdentifiers(xcodes)

        XCTAssertEqual(filtered.count, 1)
        #if arch(arm64)
        XCTAssertEqual(filtered[0].filename, "Xcode_26.3_Release_Candidate_Apple_silicon.xip")
        #else
        XCTAssertEqual(filtered[0].filename, "Xcode_26.3_Release_Candidate_Universal.xip")
        #endif
    }
}
