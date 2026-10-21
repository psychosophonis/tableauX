import XCTest
@testable import PlayerCore

/// [claude] v4 playlists (docs/architecture.md § v4): T14 (folder scan and
/// merge) and T15 (the timeline as a pure function).
final class FolderScanTests: XCTestCase {
    func testNaturalOrderPutsTwoBeforeTen() {
        XCTAssertEqual(FolderScan.videos(["10.mp4", "2.mp4", "1.mp4"]), ["1.mp4", "2.mp4", "10.mp4"])
    }

    func testOnlyVisibleVideoFilesCount() {
        let listing = [".DS_Store", "._1.mov", "notes.txt", "1.MOV", "2.m4v", "poster.jpg", "3.mp4"]
        XCTAssertEqual(FolderScan.videos(listing), ["1.MOV", "2.m4v", "3.mp4"])
    }

    func testTwoFilesOnThreeDisplaysLeaveTheThirdBlackWithAudioOff() {
        let (panels, left) = FolderScan.assign(folder: "Smith", files: ["b.mp4", "a.mp4"], displays: 3)
        XCTAssertEqual(panels.map(\.file), ["Smith/a.mp4", "Smith/b.mp4", nil])
        XCTAssertTrue(panels.allSatisfy { !$0.audio })
        XCTAssertEqual(left, [])
    }

    func testExtraFilesAreLeftOverInOrder() {
        let (panels, left) = FolderScan.assign(folder: "W", files: ["4.mp4", "1.mp4", "3.mp4", "2.mp4"], displays: 2)
        XCTAssertEqual(panels.map(\.file), ["W/1.mp4", "W/2.mp4"])
        XCTAssertEqual(left, ["3.mp4", "4.mp4"])
    }
}

final class PlaylistMergeTests: XCTestCase {
    private func inv(_ machine: String, _ displays: Int, _ folders: [String: [(String, Double)]]) -> Inventory {
        Inventory(machine: machine, displays: displays,
                  folders: folders.mapValues { $0.map { InventoryFile(name: $0.0, duration: $0.1) } })
    }

    /// Mat's example: "Smith" with 2 files on one Mac and 3 on the other is
    /// one work of 5 screens, each Mac's files on its own displays.
    func testSameFolderNameOnTwoMacsIsOneWork() {
        let works = PlaylistMerge.merge([], with: [
            inv("Conductor", 3, ["Smith": [("1.mp4", 60), ("2.mp4", 60)]]),
            inv("Player", 3, ["Smith": [("3.mp4", 60), ("4.mp4", 60), ("5.mp4", 60)]]),
        ])
        XCTAssertEqual(works.count, 1)
        XCTAssertEqual(works[0].screens["Conductor"]?.map(\.file), ["Smith/1.mp4", "Smith/2.mp4", nil])
        XCTAssertEqual(works[0].screens["Player"]?.map(\.file), ["Smith/3.mp4", "Smith/4.mp4", "Smith/5.mp4"])
    }

    func testAFolderOnOnlyOneMacLeavesTheOtherBlack() {
        let works = PlaylistMerge.merge([], with: [inv("A", 3, ["Lee": [("1.mp4", 30)]]), inv("B", 3, [:])])
        XCTAssertNotNil(works[0].screens["A"])
        XCTAssertNil(works[0].screens["B"])            // no entry = black on B
    }

    func testNewWorksArriveInNaturalOrder() {
        let works = PlaylistMerge.merge([], with: [inv("A", 1, ["Work 10": [("1.mp4", 1)], "Work 2": [("1.mp4", 1)], "Work 1": [("1.mp4", 1)]])])
        XCTAssertEqual(works.map(\.name), ["Work 1", "Work 2", "Work 10"])
    }

    /// A rescan must not undo what a person set up: order, repeat, and
    /// screens chosen by hand all survive; only new folders are added.
    func testRescanKeepsExistingWorksAndAppendsNewOnes() {
        var lee = Work(name: "Lee", screens: ["A": [PanelConfig(file: "Lee/chosen-by-hand.mp4", audio: true)]], repeat: .untilNext)
        lee.shorter = .loop
        let works = PlaylistMerge.merge([lee, Work(name: "Abe")], with: [inv("A", 1, ["Abe": [("1.mp4", 1)], "Lee": [("1.mp4", 1)], "Cho": [("1.mp4", 1)]])])
        XCTAssertEqual(works.map(\.name), ["Lee", "Abe", "Cho"])
        XCTAssertEqual(works[0], lee)
        XCTAssertEqual(works[1].screens["A"]?.first?.file, "Abe/1.mp4")   // had no screens on A: filled
    }

    func testAMacJoiningLaterFillsItsScreensOfExistingWorks() {
        let first = PlaylistMerge.merge([], with: [inv("A", 1, ["Smith": [("1.mp4", 10)]])])
        let later = PlaylistMerge.merge(first, with: [inv("A", 1, ["Smith": [("1.mp4", 10)]]), inv("B", 1, ["Smith": [("2.mp4", 10)]])])
        XCTAssertEqual(later[0].screens["B"]?.first?.file, "Smith/2.mp4")
    }

    func testWorkLengthIsTheLongestFileOnAnyMac() {
        let invs = [inv("A", 2, ["W": [("1.mp4", 30), ("2.mp4", 45)]]), inv("B", 1, ["W": [("3.mp4", 90)]])]
        let w = PlaylistMerge.merge([], with: invs)[0]
        XCTAssertEqual(PlaylistMerge.length(of: w, in: invs), 90)
    }

    func testRepeatIsStoredReadably() throws {
        let enc = JSONEncoder()
        XCTAssertEqual(String(data: try enc.encode([Repeat.once, .times(3), .untilNext]), encoding: .utf8), #"[1,3,"untilNext"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Repeat].self, from: Data(#"[1,3,"untilNext"]"#.utf8)), [.once, .times(3), .untilNext])
        XCTAssertThrowsError(try JSONDecoder().decode([Repeat].self, from: Data("[0]".utf8)))
    }
}

final class TimelineTests: XCTestCase {
    /// Three works of 60 s, 30 s (twice) and 45 s, gap 3 s, looping.
    private let t = Timeline(entries: [.init(length: 60, repeat: .once),
                                       .init(length: 30, repeat: .times(2)),
                                       .init(length: 45, repeat: .once)],
                             settings: PlaylistSettings(gap: 3, loop: true))

    func testWalksWorksAndGaps() {
        XCTAssertEqual(t.position(at: 1000, anchor: 0, start: 1000), .work(index: 0, elapsed: 0))
        XCTAssertEqual(t.position(at: 1059, anchor: 0, start: 1000), .work(index: 0, elapsed: 59))
        XCTAssertEqual(t.position(at: 1061, anchor: 0, start: 1000), .gap(next: 1))
        XCTAssertEqual(t.position(at: 1063, anchor: 0, start: 1000), .work(index: 1, elapsed: 0))
        XCTAssertEqual(t.position(at: 1063 + 59, anchor: 0, start: 1000), .work(index: 1, elapsed: 59))   // second play
        XCTAssertEqual(t.position(at: 1063 + 60 + 3, anchor: 0, start: 1000), .work(index: 2, elapsed: 0))
    }

    func testLoopsBackToTheFirstWork() {
        // Cycle = 60+3 + 60+3 + 45+3 = 174 s.
        XCTAssertEqual(t.position(at: 1000 + 174, anchor: 0, start: 1000), .work(index: 0, elapsed: 0))
        XCTAssertEqual(t.position(at: 1000 + 174 + 10, anchor: 0, start: 1000), .work(index: 0, elapsed: 10))
    }

    /// A thousand cycles after the anchor (about two days), the answer is
    /// stated outright: 70 s into a cycle is work 1, 7 s in. (An earlier
    /// version compared against one day, 86 400 s, which by coincidence lands
    /// in the same place even with the gaps left out of the cycle: a mutant
    /// that dropped them survived. 174 000 + 70 doesn't have that blind spot.)
    func testFarFutureUsesTheCycle() {
        XCTAssertEqual(t.position(at: 1000 + 174 * 1000 + 70, anchor: 0, start: 1000), .work(index: 1, elapsed: 7))
    }

    func testAnchoredMidPlaylist() {
        // Someone pressed Next to work 2 at show time 500.
        XCTAssertEqual(t.position(at: 510, anchor: 2, start: 500), .work(index: 2, elapsed: 10))
        XCTAssertEqual(t.position(at: 500 + 45 + 1, anchor: 2, start: 500), .gap(next: 0))
        XCTAssertEqual(t.position(at: 499, anchor: 2, start: 500), .waiting)
    }

    func testWithoutLoopItEnds() {
        let once = Timeline(entries: t.entries, settings: PlaylistSettings(gap: 3, loop: false))
        XCTAssertEqual(once.position(at: 1000 + 60 + 3 + 60 + 3 + 44, anchor: 0, start: 1000), .work(index: 2, elapsed: 44))
        XCTAssertEqual(once.position(at: 1000 + 60 + 3 + 60 + 3 + 46, anchor: 0, start: 1000), .ended)
    }

    func testUntilNextHoldsForever() {
        let held = Timeline(entries: [.init(length: 60, repeat: .once), .init(length: 20, repeat: .untilNext), .init(length: 10, repeat: .once)],
                            settings: .standard)
        XCTAssertEqual(held.position(at: 63 + 10_000, anchor: 0, start: 0), .work(index: 1, elapsed: 10_000))
    }

    func testEmptyWorksAreSkippedWithoutAGap() {
        let gappy = Timeline(entries: [.init(length: 10, repeat: .once), .init(length: 0, repeat: .once), .init(length: 10, repeat: .once)],
                             settings: PlaylistSettings(gap: 2, loop: true))
        XCTAssertEqual(gappy.position(at: 11, anchor: 0, start: 0), .gap(next: 2))
        XCTAssertEqual(gappy.position(at: 12, anchor: 0, start: 0), .work(index: 2, elapsed: 0))
        XCTAssertEqual(Timeline(entries: [.init(length: 0, repeat: .once)], settings: .standard).position(at: 5, anchor: 0, start: 0), .ended)
    }

    func testShorterScreensGoBlackOrLoop() {
        // A 20 s file in a 60 s work, played twice.
        XCTAssertEqual(Timeline.screenPosition(elapsed: 10, workLength: 60, fileDuration: 20, shorter: .black), 10)
        XCTAssertNil(Timeline.screenPosition(elapsed: 25, workLength: 60, fileDuration: 20, shorter: .black))
        XCTAssertEqual(Timeline.screenPosition(elapsed: 65, workLength: 60, fileDuration: 20, shorter: .black), 5)    // second play restarts it
        XCTAssertEqual(Timeline.screenPosition(elapsed: 25, workLength: 60, fileDuration: 20, shorter: .loop), 5)
    }
}
