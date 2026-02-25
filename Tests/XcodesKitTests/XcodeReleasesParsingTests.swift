import XCTest
import Version
@testable import XcodesKit

final class XcodeReleasesParsingTests: XCTestCase {
    func test_ParseXcodeReleases_Parses262AndLater() throws {
        let data = """
        [
          {
            "name": "Xcode",
            "version": {
              "number": "26.2",
              "build": "17C5006k",
              "release": { "release": true }
            },
            "date": { "year": 2026, "month": 1, "day": 15 },
            "requires": "macOS 15",
            "links": {
              "download": { "url": "https://download.developer.apple.com/Developer_Tools/Xcode_26.2/Xcode_26.2.xip" }
            }
          },
          {
            "name": "Xcode",
            "version": {
              "number": "26.2.1",
              "build": "17C6001a",
              "release": { "rc": 2 }
            },
            "date": { "year": 2026, "month": 1, "day": 22 },
            "requires": "macOS 15",
            "links": {
              "download": { "url": "https://download.developer.apple.com/Developer_Tools/Xcode_26.2.1_Release_Candidate_2/Xcode_26.2.1_Release_Candidate_2.xip" }
            }
          }
        ]
        """.data(using: .utf8)!

        let xcodes = try XcodeList().parseXcodeReleases(from: data)

        XCTAssertEqual(xcodes.count, 2)
        XCTAssertEqual(xcodes[0].version, Version("26.2.0+17C5006k"))
        XCTAssertEqual(xcodes[1].version, Version("26.2.1-Release.Candidate.2+17C6001a"))
    }

    func test_ParseXcodeReleases_DoesNotFailOnUnknownReleaseShape() throws {
        let data = """
        [
          {
            "name": "Xcode",
            "version": {
              "number": "26.3",
              "build": "17D7000b",
              "release": { "preview": 1 }
            },
            "date": { "year": 2026, "month": 2, "day": 1 },
            "requires": "macOS 15",
            "links": {
              "download": { "url": "https://download.developer.apple.com/Developer_Tools/Xcode_26.3/Xcode_26.3.xip" }
            }
          }
        ]
        """.data(using: .utf8)!

        let xcodes = try XcodeList().parseXcodeReleases(from: data)

        XCTAssertEqual(xcodes.count, 1)
        XCTAssertEqual(xcodes[0].version, Version("26.3.0+17D7000b"))
    }
}
