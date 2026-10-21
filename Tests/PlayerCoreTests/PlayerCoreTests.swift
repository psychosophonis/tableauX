import XCTest
import CoreGraphics
@testable import PlayerCore

final class DisplayOrderTests: XCTestCase {
    private func d(_ id: UInt32, x: CGFloat, y: CGFloat = 0) -> DisplayInfo {
        DisplayInfo(id: id, name: "\(id)", frame: CGRect(x: x, y: y, width: 1920, height: 1080),
                    pixelSize: CGSize(width: 3840, height: 2160))
    }

    func testLeftToRightRegardlessOfInputOrder() {
        let shuffled = [d(7, x: 1920), d(3, x: 3840), d(9, x: 0)]
        XCTAssertEqual(DisplayOrder.sorted(shuffled).map(\.id), [9, 7, 3])
    }

    func testStackedDisplaysTieBreakOnYThenId() {
        let input = [d(2, x: 0, y: 1080), d(5, x: 0, y: 0), d(1, x: 0, y: 0)]
        XCTAssertEqual(DisplayOrder.sorted(input).map(\.id), [1, 5, 2])
    }

    func testDisplayLeftOfMainHasNegativeX() {
        // macOS puts the main display at x = 0; a screen arranged to its left has negative x.
        XCTAssertEqual(DisplayOrder.sorted([d(1, x: 0), d(2, x: -1920)]).map(\.id), [2, 1])
    }
}

final class PlacementTests: XCTestCase {
    func testHDOnUHDIsExactlyDouble() {
        let s = Placement.scale(video: CGSize(width: 1920, height: 1080), display: CGSize(width: 3840, height: 2160), scaling: .fit)
        XCTAssertEqual(s, 2)
    }

    func testFitTakesSmallerAxisFillTakesLarger() {
        // A square video on a 16:9 display: fit is limited by height, fill by width.
        let v = CGSize(width: 1080, height: 1080), disp = CGSize(width: 3840, height: 2160)
        XCTAssertEqual(Placement.scale(video: v, display: disp, scaling: .fit), 2)
        XCTAssertEqual(Placement.scale(video: v, display: disp, scaling: .fill), 3840.0 / 1080.0, accuracy: 1e-9)
    }

    func testScaledVideoNeverOverflowsOnFitOrFallsShortOnFill() {
        let v = CGSize(width: 1280, height: 720), disp = CGSize(width: 3840, height: 1600)
        let fit = Placement.scale(video: v, display: disp, scaling: .fit)
        XCTAssertLessThanOrEqual(v.width * fit, disp.width)
        XCTAssertLessThanOrEqual(v.height * fit, disp.height)
        let fill = Placement.scale(video: v, display: disp, scaling: .fill)
        XCTAssertGreaterThanOrEqual(v.width * fill, disp.width)
        XCTAssertGreaterThanOrEqual(v.height * fill, disp.height)
    }

    func testZeroSizedVideoGivesZeroNotInfinity() {
        XCTAssertEqual(Placement.scale(video: .zero, display: CGSize(width: 10, height: 10), scaling: .fit), 0)
    }
}

final class SyncMathTests: XCTestCase {
    func testExpectedWrapsToItemLength() {
        XCTAssertEqual(SyncMath.expected(host: 1061, start: 1000, duration: 60), 1, accuracy: 1e-9)
        XCTAssertEqual(SyncMath.expected(host: 1000, start: 1000, duration: 60), 0, accuracy: 1e-9)
    }

    func testExpectedBeforeStartIsStillInRange() {
        // Asking about an instant before the shared start must still land in [0, duration).
        XCTAssertEqual(SyncMath.expected(host: 999, start: 1000, duration: 60), 59, accuracy: 1e-9)
    }

    func testCircularDistanceAcrossTheWrap() {
        XCTAssertEqual(SyncMath.circularDistance(0.01, 59.99, duration: 60), 0.02, accuracy: 1e-9)
        XCTAssertEqual(SyncMath.circularDistance(10, 40, duration: 60), 30, accuracy: 1e-9)
    }

    func testDeadbandIsOneFrame() {
        let frame = 1.0 / 30
        XCTAssertFalse(SyncMath.needsCorrection(actual: 5.02, expected: 5.0, duration: 60, frame: frame))
        XCTAssertTrue(SyncMath.needsCorrection(actual: 5.05, expected: 5.0, duration: 60, frame: frame))
        // Just past the wrap is not an error.
        XCTAssertFalse(SyncMath.needsCorrection(actual: 0.01, expected: 59.995, duration: 60, frame: frame))
    }

    func testResumeContinuesWherePaused() {
        // Started at 1000, paused 10 s in, resumed at 1050: still 10 s in.
        let start = SyncMath.resumedStart(start: 1000, pausedAt: 1010, resumeAt: 1050)
        XCTAssertEqual(SyncMath.expected(host: 1050, start: start, duration: 60), 10, accuracy: 1e-9)
    }

    func testPauseBeforeTheScheduledStartResumesFromZero() {
        // Play scheduled for 1000; Space at 999.5, again at 1005. Must resume at 0,
        // not wrap to the end of the item (the bug this guards against).
        let start = SyncMath.resumedStart(start: 1000, pausedAt: 999.5, resumeAt: 1005)
        XCTAssertEqual(SyncMath.expected(host: 1005, start: start, duration: 86_400), 0, accuracy: 1e-9)
    }

    func testRepeatsCoverButAreCapped() {
        XCTAssertEqual(SyncMath.repeats(duration: 10, cover: 3600, maxSegments: 10_000), 360)
        XCTAssertEqual(SyncMath.repeats(duration: 1, cover: 86_400, maxSegments: 2_000), 2_000)
        XCTAssertEqual(SyncMath.repeats(duration: 7200, cover: 3600, maxSegments: 2_000), 1)
        XCTAssertEqual(SyncMath.repeats(duration: 0, cover: 3600, maxSegments: 2_000), 1)
    }
}

final class ShowFileTests: XCTestCase {
    func testRoundTrip() throws {
        let show = Show(panels: [PanelConfig(file: "/a.mp4", audio: true, scaling: .fill),
                                 PanelConfig(),
                                 PanelConfig(file: "/c.mov")],
                        playOnLaunch: true)
        XCTAssertEqual(try ShowFile.decode(ShowFile.encode(show)), show)
    }

    func testRefusesAFutureVersion() {
        let json = #"{"version":2,"panels":[],"playOnLaunch":false}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ShowFile.decode(json)) {
            XCTAssertEqual($0 as? ShowFileError, .unsupportedVersion(2))
        }
    }

    func testUnknownScalingIsAnError() {
        let json = #"{"version":1,"panels":[{"audio":false,"scaling":"stretch"}],"playOnLaunch":false}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ShowFile.decode(json))
    }
}
