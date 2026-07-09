import XCTest
@testable import PaveKit

final class ConfidencePolicyTests: XCTestCase {
    private let cfg = PaveConfig()   // discovered=3, suggestConf=0.8, suggestLen=3

    func testSuggestedAtExactBoundaries() {
        let t = ConfidencePolicy.tier(occurrences: 3, confidence: 0.8, sampleCount: 3,
                                      runLength: 3, isAppSwitchOnly: false, config: cfg)
        XCTAssertEqual(t, .suggested)
    }

    func testDiscoveredWhenConfidenceTooLow() {
        let t = ConfidencePolicy.tier(occurrences: 3, confidence: 0.79, sampleCount: 4,
                                      runLength: 3, isAppSwitchOnly: false, config: cfg)
        XCTAssertEqual(t, .discovered)
    }

    func testNoneBelowOccurrences() {
        let t = ConfidencePolicy.tier(occurrences: 2, confidence: 1.0, sampleCount: 2,
                                      runLength: 4, isAppSwitchOnly: false, config: cfg)
        XCTAssertEqual(t, .none)
    }

    func testNoneWhenRunTooShort() {
        let t = ConfidencePolicy.tier(occurrences: 5, confidence: 1.0, sampleCount: 5,
                                      runLength: 2, isAppSwitchOnly: false, config: cfg)
        XCTAssertEqual(t, .none)
    }

    func testAppSwitchOnlyNeverPasses() {
        let t = ConfidencePolicy.tier(occurrences: 99, confidence: 1.0, sampleCount: 99,
                                      runLength: 6, isAppSwitchOnly: true, config: cfg)
        XCTAssertEqual(t, .none)
    }

    func testZeroSampleIsSilent() {
        let t = ConfidencePolicy.tier(occurrences: 3, confidence: 1.0, sampleCount: 0,
                                      runLength: 3, isAppSwitchOnly: false, config: cfg)
        XCTAssertEqual(t, .none)
    }

    func testIsAppSwitchOnlyDetection() {
        let apps = [PaveFingerprint(kind: .appActivated, bundleID: "a"),
                    PaveFingerprint(kind: .appLaunched, bundleID: "b"),
                    PaveFingerprint(kind: .appTerminated, bundleID: "c")]
        XCTAssertTrue(ConfidencePolicy.isAppSwitchOnly(apps))

        let mixed = apps + [PaveFingerprint(kind: .fileMoved, folder: "~/x", fileExtension: "pdf")]
        XCTAssertFalse(ConfidencePolicy.isAppSwitchOnly(mixed))

        XCTAssertFalse(ConfidencePolicy.isAppSwitchOnly([]))
    }
}
