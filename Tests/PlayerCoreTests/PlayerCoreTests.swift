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

    // [claude] A show's tolerance widens the deadband in whole frames.
    func testToleranceWidensTheDeadband() {
        let frame = 1.0 / 30
        // 2.5 frames out: corrected at tolerance 1 and 2, left alone at 3.
        let actual = 5.0 + 2.5 * frame
        XCTAssertTrue(SyncMath.needsCorrection(actual: actual, expected: 5, duration: 60, frame: frame, tolerance: 2))
        XCTAssertFalse(SyncMath.needsCorrection(actual: actual, expected: 5, duration: 60, frame: frame, tolerance: 3))
        // A tolerance below 1 is treated as 1, never as "correct everything".
        XCTAssertFalse(SyncMath.needsCorrection(actual: 5.02, expected: 5, duration: 60, frame: frame, tolerance: 0))
    }

    // [claude] Stage 3a: start on time when there's time, else join in sync.
    func testStartStillAheadStartsOnItFromZero() {
        let at = SyncMath.scheduledStart(start: 1001, now: 1000)
        XCTAssertEqual(at, 1001)
        XCTAssertEqual(SyncMath.expected(host: at, start: 1001, duration: 60), 0, accuracy: 1e-9)
    }

    func testStartPassedJoinsWhereTheShowHasGot() {
        // Files took 3 s longer than the conductor's 1 s lead.
        let at = SyncMath.scheduledStart(start: 1001, now: 1004)
        XCTAssertEqual(at, 1004.5)
        XCTAssertEqual(SyncMath.expected(host: at, start: 1001, duration: 60), 3.5, accuracy: 1e-9)
        // And a very late join wraps onto the loop.
        let late = SyncMath.scheduledStart(start: 1001, now: 1100)
        XCTAssertEqual(SyncMath.expected(host: late, start: 1001, duration: 60), 39.5, accuracy: 1e-9)
    }

    func testStartTooCloseToScheduleIsTreatedAsPassed() {
        // 50 ms ahead is too close to schedule reliably: join 0.5 s on instead.
        XCTAssertEqual(SyncMath.scheduledStart(start: 1000.05, now: 1000), 1000.5)
    }

    // [claude] DriftGate: grace 0 is v1 (correct at the first check out).
    func testZeroGraceCorrectsAtOnce() {
        var gate = DriftGate(grace: 0)
        XCTAssertTrue(gate.check(out: true, now: 100))
    }

    func testGraceWaitsThenFiresOnce() {
        var gate = DriftGate(grace: 5)
        // Checks once a second, panel out the whole time.
        let fired = (0...10).map { gate.check(out: true, now: 100 + Double($0)) }
        // Fires at 5 s (the first check that has been out for the full grace),
        // then the wait starts again, so the next is at 6 + 5 = 11 s.
        XCTAssertEqual(fired.enumerated().filter(\.element).map(\.offset), [5])
    }

    func testComingBackRestartsTheGrace() {
        var gate = DriftGate(grace: 5)
        for t in 0..<4 { XCTAssertFalse(gate.check(out: true, now: Double(t))) }
        XCTAssertFalse(gate.check(out: false, now: 4))      // a blip, then back in tolerance
        for t in 5..<10 { XCTAssertFalse(gate.check(out: true, now: Double(t))) }
        XCTAssertTrue(gate.check(out: true, now: 10))       // 5 s out since t = 5
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
        let smith = Work(name: "Smith",
                         screens: ["Lab Mac mini": [PanelConfig(file: "Smith/1.mp4", audio: true, scaling: .fill),
                                                    PanelConfig(),
                                                    PanelConfig(file: "/elsewhere/c.mov")],
                                   "MacBook Pro": [PanelConfig(file: "Smith/2.mov")]],
                         repeat: .times(2), shorter: .loop)
        let show = Show(machines: [Machine(name: "Lab Mac mini", displays: 3), Machine(name: "MacBook Pro", displays: 1)],
                        works: [smith, Work(name: "Lee", repeat: .untilNext)],
                        playlist: PlaylistSettings(gap: 5, loop: false),
                        sync: SyncSettings(tolerance: 1, grace: 10),
                        playOnLaunch: true)
        XCTAssertEqual(try ShowFile.decode(ShowFile.encode(show)), show)
    }

    private func json(_ s: String) -> Data { s.data(using: .utf8)! }
    private let sync = #""sync":{"tolerance":3,"grace":5}"#
    private let rest = #""works":[],"playlist":{"gap":3,"loop":true},"playOnLaunch":false"#

    func testNewShowHasMatsDefaults() {
        let show = Show(machines: [Machine(name: "A")])
        XCTAssertEqual(show.sync, SyncSettings(tolerance: 3, grace: 5))
        XCTAssertEqual(show.playlist, PlaylistSettings(gap: 3, loop: true))
        XCTAssertEqual(show.version, 3)
    }

    /// [claude] § v4 › Model: a version 2 show opens as a one-work playlist
    /// that plays as it always did (until stopped, each panel looping on its
    /// own length), with every machine's panels and absolute paths kept.
    func testVersion2OpensAsOneWorkThatLoopsUntilStopped() throws {
        let v2 = #"{"version":2,"machines":[{"name":"Lab","panels":[{"file":"/v/a.mp4","audio":true,"scaling":"fill"},{"audio":false,"scaling":"fit"}]},"#
            + #"{"name":"Laptop","panels":[{"file":"/v/b.mp4","audio":false,"scaling":"fit"}]}],"#
            + sync + #","playOnLaunch":true}"#
        let show = try ShowFile.decode(json(v2))
        XCTAssertEqual(show.version, 3)
        XCTAssertEqual(show.machines, [Machine(name: "Lab", displays: 2), Machine(name: "Laptop", displays: 1)])
        XCTAssertEqual(show.works.count, 1)
        XCTAssertEqual(show.works[0].repeat, .untilNext)
        XCTAssertEqual(show.works[0].shorter, .loop)
        XCTAssertEqual(show.works[0].screens["Lab"], [PanelConfig(file: "/v/a.mp4", audio: true, scaling: .fill), PanelConfig()])
        XCTAssertEqual(show.works[0].screens["Laptop"]?.first?.file, "/v/b.mp4")
        XCTAssertTrue(show.playOnLaunch)
        // Saved again, it is a version 3 file.
        XCTAssertEqual(try ShowFile.decode(ShowFile.encode(show)), show)
    }

    func testRefusesANegativeGap() {
        let s = #"{"version":3,"machines":[{"name":"A","displays":1}],"works":[],"playlist":{"gap":-1,"loop":true},"# + sync + #","playOnLaunch":false}"#
        XCTAssertThrowsError(try ShowFile.decode(json(s))) { XCTAssertEqual($0 as? ShowFileError, .invalidGap(-1)) }
    }

    // [claude] Version 1 (0.1.1) files are refused, by name, not with a
    // confusing "missing key" error: the version is checked first.
    func testRefusesVersion1() {
        XCTAssertThrowsError(try ShowFile.decode(json(#"{"version":1,"panels":[],"playOnLaunch":false}"#))) {
            XCTAssertEqual($0 as? ShowFileError, .unsupportedVersion(1))
        }
    }

    func testRefusesAFutureVersion() {
        XCTAssertThrowsError(try ShowFile.decode(json(#"{"version":4,"machines":[],"playOnLaunch":false}"#))) {
            XCTAssertEqual($0 as? ShowFileError, .unsupportedVersion(4))
        }
    }

    func testUnknownScalingIsAnError() {
        let s = #"{"version":3,"machines":[{"name":"A","displays":1}],"works":[{"name":"W","screens":{"A":[{"audio":false,"scaling":"stretch"}]},"repeat":1,"shorter":"black"}],"#
            + #""playlist":{"gap":3,"loop":true},"# + sync + #","playOnLaunch":false}"#
        XCTAssertThrowsError(try ShowFile.decode(json(s)))
    }

    func testAShowNeedsAMachine() {
        for v in [#"{"version":3,"machines":[],"# + sync + "," + rest + "}",
                  #"{"version":2,"machines":[],"# + sync + #","playOnLaunch":false}"#] {
            XCTAssertThrowsError(try ShowFile.decode(json(v))) { XCTAssertEqual($0 as? ShowFileError, .noMachines) }
        }
    }

    func testRefusesNonsenseSync() {
        for bad in [#""sync":{"tolerance":0,"grace":5}"#, #""sync":{"tolerance":3,"grace":-1}"#] {
            XCTAssertThrowsError(try ShowFile.decode(json(#"{"version":3,"machines":[{"name":"A","displays":1}],"# + bad + "," + rest + "}")))
        }
    }

    // [claude] § Show file › which machine this Mac plays.
    func testMachineIsFoundByName() {
        let show = Show(machines: [Machine(name: "A"), Machine(name: "B")])
        XCTAssertEqual(show.machineIndex(named: "B"), 1)
    }

    func testAOneMachineShowPlaysOnAnyMac() {
        XCTAssertEqual(Show(machines: [Machine(name: "Laptop")]).machineIndex(named: "Lab Mac mini"), 0)
    }

    func testSeveralMachinesAndNoMatchIsNoPart() {
        XCTAssertNil(Show(machines: [Machine(name: "A"), Machine(name: "B")]).machineIndex(named: "C"))
    }
}
