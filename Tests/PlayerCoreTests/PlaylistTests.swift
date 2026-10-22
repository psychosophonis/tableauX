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

/// [claude] Files that name their screen, "_N" across the tableau (Mat, 2026-10-22).
final class ScreenNumberTests: XCTestCase {
    func testOnlyAnUnderscoreNumberAtTheEndCounts() {
        XCTAssertEqual(FolderScan.screenNumber("Comp 4_5.mov"), 5)
        XCTAssertEqual(FolderScan.screenNumber("Smith final_12.mp4"), 12)
        XCTAssertNil(FolderScan.screenNumber("10.mp4"))
        XCTAssertNil(FolderScan.screenNumber("draft_v2.mov"))
        XCTAssertNil(FolderScan.screenNumber("x_0.mov"))
        XCTAssertNil(FolderScan.screenNumber("x_.mov"))
    }

    /// Mat's files: numbered in screen order already, so the same result.
    func testMatsCompFilesLandInOrder() {
        let (panels, left) = FolderScan.assign(folder: "work1", files: ["Comp 4_3.mov", "Comp 4_1.mov", "Comp 4_2.mov"], displays: 2)
        XCTAssertEqual(panels.map(\.file), ["work1/Comp 4_1.mov", "work1/Comp 4_2.mov"])
        XCTAssertEqual(left, ["Comp 4_3.mov"])
    }

    func testTheNumberDecidesNotTheNameAndAGapStaysBlack() {
        let (panels, _) = FolderScan.assign(folder: "W", files: ["final_3.mov", "draft_1.mov"], displays: 3)
        XCTAssertEqual(panels.map(\.file), ["W/draft_1.mov", nil, "W/final_3.mov"])
    }

    /// The second Mac of a 3+3 tableau: its screens are 4–6. A file numbered
    /// for the first Mac is left over ("not on this Mac").
    func testASecondMacTakesItsOwnNumbers() {
        let (panels, left) = FolderScan.assign(folder: "W", files: ["p_5.mov", "p_4.mov", "p_2.mov"], displays: 3, firstScreen: 4)
        XCTAssertEqual(panels.map(\.file), ["W/p_4.mov", "W/p_5.mov", nil])
        XCTAssertEqual(left, ["p_2.mov"])
    }

    func testUnnumberedFilesFillTheGapsAndDuplicatesAreLeftOver() {
        let (panels, left) = FolderScan.assign(folder: "W", files: ["a_2.mov", "b_2.mov", "loose.mov"], displays: 2)
        XCTAssertEqual(panels.map(\.file), ["W/loose.mov", "W/a_2.mov"])
        XCTAssertEqual(left, ["b_2.mov"])
    }

    func testANewDisplayTakesTheFileNumberedForIt() {
        let (panels, _) = FolderScan.fill([PanelConfig(file: "W/s_1.mov")], folder: "W",
                                          files: ["s_1.mov", "s_3.mov"], displays: 3)
        XCTAssertEqual(panels.map(\.file), ["W/s_1.mov", nil, "W/s_3.mov"])     // the gap is stored: s_3 is screen 3
    }

    func testTheConductorPlacesAPlayersNumbersAfterItsOwnScreens() {
        let s = Show(machines: [Machine(name: "A", displays: 3)])
        XCTAssertEqual(SharedShow.firstScreen(s, of: "A"), 1)
        let inv = Inventory(machine: "B", displays: 3,
                            folders: ["W": ["W_4.mov", "W_6.mov", "W_5.mov"].map { InventoryFile(name: $0, duration: 5) }])
        let m = SharedShow.merge(s, with: inv, conductor: "A")
        XCTAssertEqual(SharedShow.firstScreen(m, of: "B"), 4)
        XCTAssertEqual(m.works[0].screens["B"]?.map(\.file), ["W/W_4.mov", "W/W_5.mov", "W/W_6.mov"])
    }
}

/// [claude] P4e: the whole tableau laid out for one screen.
final class PreviewLayoutTests: XCTestCase {
    func testARowPerMacScreensNumberedAcrossAndBlackWhereUnset() {
        let show = Show(machines: [Machine(name: "A", displays: 2), Machine(name: "B", displays: 3)])
        let work = Work(name: "W", screens: ["A": [PanelConfig(file: "W/W_1.mov")],
                                            "B": [PanelConfig(file: "W/W_3.mov"), PanelConfig(), PanelConfig(file: "W/W_5.mov")]])
        let rows = PreviewLayout.rows(show, work: work)
        XCTAssertEqual(rows.map { $0.map(\.machine) }, [["A", "A"], ["B", "B", "B"]])
        XCTAssertEqual(rows.flatMap { $0.map(\.screen) }, [1, 2, 3, 4, 5])
        XCTAssertEqual(rows[1].map(\.display), [1, 2, 3])
        XCTAssertEqual(rows.flatMap { $0.map(\.panel.file) }, ["W/W_1.mov", nil, "W/W_3.mov", nil, "W/W_5.mov"])
    }

    func testAMacWithNoScreensForTheWorkStillHasItsTiles() {
        let show = Show(machines: [Machine(name: "A", displays: 1), Machine(name: "B", displays: 2)])
        XCTAssertEqual(PreviewLayout.rows(show, work: Work(name: "W")).map(\.count), [1, 2])
    }
}

/// [claude] A display added after the scan takes the left-over files.
final class FillTests: XCTestCase {
    private let files = ["3.mp4", "1.mp4", "10.mp4", "2.mp4", "notes.txt"]

    func testNewDisplaysTakeTheUnusedFilesInOrder() {
        let (scanned, _) = FolderScan.assign(folder: "W", files: files, displays: 2)
        let (panels, left) = FolderScan.fill(scanned, folder: "W", files: files, displays: 3)
        XCTAssertEqual(panels.map(\.file), ["W/1.mp4", "W/2.mp4", "W/3.mp4"])
        XCTAssertEqual(left, ["10.mp4"])
    }

    func testPanelsAlreadySetAreKeptEvenBlackOrByHand() {
        let set = [PanelConfig(file: "W/3.mp4", audio: true), PanelConfig()]
        let (panels, left) = FolderScan.fill(set, folder: "W", files: files, displays: 4)
        XCTAssertEqual(panels.map(\.file), ["W/3.mp4", nil, "W/1.mp4", "W/2.mp4"])
        XCTAssertTrue(panels[0].audio)
        XCTAssertEqual(left, ["10.mp4"])
    }

    /// Out of files: the rest stay unset (black), so a file added later
    /// still fills them; they are not stored as black.
    func testRunningOutOfFilesLeavesTheRestUnset() {
        let one = [PanelConfig(file: "/x/W/1.mp4")]
        let (panels, left) = FolderScan.fill(one, folder: "/x/W", files: ["1.mp4"], displays: 3)
        XCTAssertEqual(panels, one)
        XCTAssertEqual(left, [])
        let (later, _) = FolderScan.fill(panels, folder: "/x/W", files: ["1.mp4", "2.mp4"], displays: 3)
        XCTAssertEqual(later.map(\.file), ["/x/W/1.mp4", "/x/W/2.mp4"])
    }

    func testAWorksFolderIsItsFilesOneFolderOrItsName() {
        XCTAssertEqual(FolderScan.folder(of: [PanelConfig(file: "W/1.mp4"), PanelConfig()], work: "X"), "W")
        XCTAssertEqual(FolderScan.folder(of: [PanelConfig(file: "/a/W/1.mp4")], work: "X"), "/a/W")
        XCTAssertEqual(FolderScan.folder(of: [PanelConfig()], work: "X"), "X")
        XCTAssertNil(FolderScan.folder(of: [PanelConfig(file: "A/1.mp4"), PanelConfig(file: "B/1.mp4")], work: "X"))
        XCTAssertNil(FolderScan.folder(of: [PanelConfig(file: "1.mp4")], work: "X"))   // loose in the media folder
    }

    func testNoChangeWhenThePanelsCoverTheDisplays() {
        let set = [PanelConfig(file: "W/1.mp4"), PanelConfig()]
        let (panels, left) = FolderScan.fill(set, folder: "W", files: files, displays: 2)
        XCTAssertEqual(panels, set)
        XCTAssertEqual(left, ["2.mp4", "3.mp4", "10.mp4"])
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

    /// [claude] The edges playback sets its one timer from.
    func testSegmentsGiveTheirEdgesInShowTime() {
        XCTAssertEqual(t.segment(at: 1010, anchor: 0, start: 1000),
                       .init(position: .work(index: 0, elapsed: 10), begins: 1000, ends: 1060))
        XCTAssertEqual(t.segment(at: 1061, anchor: 0, start: 1000),
                       .init(position: .gap(next: 1), begins: 1060, ends: 1063))
        // Work 1 plays twice: one stretch of 60 s, not two of 30.
        XCTAssertEqual(t.segment(at: 1100, anchor: 0, start: 1000),
                       .init(position: .work(index: 1, elapsed: 37), begins: 1063, ends: 1123))
        XCTAssertEqual(t.segment(at: 990, anchor: 0, start: 1000),
                       .init(position: .waiting, begins: -.infinity, ends: 1000))
    }

    /// The far-future shortcut must give the right edges too, not just the
    /// right position: 1000 cycles on, work 1 began at 70 − 7 into the cycle.
    func testFarFutureSegmentEdges() {
        let s = t.segment(at: 1000 + 174 * 1000 + 70, anchor: 0, start: 1000)
        XCTAssertEqual(s.begins, 1000 + 174 * 1000 + 63)
        XCTAssertEqual(s.ends, 1000 + 174 * 1000 + 123)
    }

    func testUntilNextAndTheEndHaveNoEnd() {
        let held = Timeline(entries: [.init(length: 20, repeat: .untilNext)], settings: .standard)
        XCTAssertNil(held.segment(at: 500, anchor: 0, start: 0).ends)
        let once = Timeline(entries: [.init(length: 10, repeat: .once)], settings: PlaylistSettings(gap: 3, loop: false))
        XCTAssertEqual(once.segment(at: 11, anchor: 0, start: 0), .init(position: .ended, begins: 10, ends: nil))
    }

    func testNextAndPreviousSkipEmptyWorksAndWrapOnlyWhenLooping() {
        let es: [Timeline.Entry] = [.init(length: 10, repeat: .once), .init(length: 0, repeat: .once), .init(length: 10, repeat: .once)]
        let looping = Timeline(entries: es, settings: PlaylistSettings(gap: 3, loop: true))
        XCTAssertEqual(looping.next(after: 0), 2)
        XCTAssertEqual(looping.previous(before: 2), 0)
        XCTAssertEqual(looping.previous(before: 0), 2)
        XCTAssertEqual(looping.playable(from: 1), 2)
        let once = Timeline(entries: es, settings: PlaylistSettings(gap: 3, loop: false))
        XCTAssertNil(once.previous(before: 0))
        XCTAssertNil(once.next(after: 2))
    }

    func testShorterScreensGoBlackOrLoop() {
        // A 20 s file in a 60 s work, played twice.
        XCTAssertEqual(Timeline.screenPosition(elapsed: 10, workLength: 60, fileDuration: 20, shorter: .black), 10)
        XCTAssertNil(Timeline.screenPosition(elapsed: 25, workLength: 60, fileDuration: 20, shorter: .black))
        XCTAssertEqual(Timeline.screenPosition(elapsed: 65, workLength: 60, fileDuration: 20, shorter: .black), 5)    // second play restarts it
        XCTAssertEqual(Timeline.screenPosition(elapsed: 25, workLength: 60, fileDuration: 20, shorter: .loop), 5)
    }
}

/// [claude] One screen's item per work: its time must equal time into the
/// work, the property `Timeline.screenPosition` states.
final class ItemLayoutTests: XCTestCase {
    private func pieces(_ d: Double, _ l: Double, _ r: Repeat, _ s: Shorter) -> [ItemLayout.Piece] {
        ItemLayout.pieces(fileDuration: d, workLength: l, repeat: r, shorter: s, cover: 86_400, maxPieces: 2_000)
    }

    func testBlackPutsEmptyTimeBetweenPlaysButNeverAtTheEnd() {
        XCTAssertEqual(pieces(20, 60, .times(2), .black), [.clip, .empty(40), .clip])
        XCTAssertEqual(pieces(20, 60, .once, .black), [.clip])
    }

    func testLoopRepeatsTheFileToCoverTheWork() {
        XCTAssertEqual(pieces(20, 60, .once, .loop), Array(repeating: .clip, count: 3))
        XCTAssertEqual(pieces(25, 60, .once, .loop).count, 3)         // 75 s ≥ 60: the end is cut by the work ending
    }

    func testTheLongestFileIsBackToBackEitherWay() {
        XCTAssertEqual(pieces(60, 60, .times(3), .black), [.clip, .clip, .clip])
    }

    /// The property itself: wherever the work is, the item laid out for it
    /// shows what `screenPosition` says (a clip at that offset, or nothing).
    func testItemTimeIsTimeIntoTheWork() {
        let d = 20.0, l = 60.0
        let layout = pieces(d, l, .times(3), .black)
        for elapsed in stride(from: 0.5, to: 180, by: 1.0) {
            var start = 0.0, found: Double?
            for p in layout {
                switch p {
                case .clip:
                    if elapsed >= start && elapsed < start + d { found = elapsed - start }
                    start += d
                case .empty(let s): start += s
                }
            }
            XCTAssertEqual(found, Timeline.screenPosition(elapsed: elapsed, workLength: l, fileDuration: d, shorter: .black), "at \(elapsed)")
        }
    }

    func testUntilNextCoversADayAndIsCapped() {
        let held = ItemLayout.pieces(fileDuration: 10, workLength: 10, repeat: .untilNext, shorter: .loop, cover: 3600, maxPieces: 2_000)
        XCTAssertEqual(held.count, 360)
        let capped = ItemLayout.pieces(fileDuration: 1, workLength: 30, repeat: .untilNext, shorter: .black, cover: 86_400, maxPieces: 2_000)
        XCTAssertLessThanOrEqual(capped.count, 2_000)
        XCTAssertEqual(capped.last, .clip)
        XCTAssertEqual(ItemLayout.duration([.clip, .empty(40), .clip], fileDuration: 20), 80)
    }

    func testNoFileNoItem() {
        XCTAssertEqual(pieces(0, 60, .once, .black), [])
    }
}
