import XCTest
@testable import PlayerCore

/// [claude] v4 P3b: the conductor–player link (docs/architecture.md § v4 ›
/// Media on several Macs).
final class LinkFramingTests: XCTestCase {
    private let messages: [LinkMessage] = [
        .hello(machine: "Mac B", build: "0.3.4"),
        .inventory(Inventory(machine: "Mac B", displays: 3,
                             folders: ["Smith": [InventoryFile(name: "1.mp4", size: 10, modified: 5, duration: 60)]])),
        .report(machine: "Mac B", blocking: ["Smith, display 1: file not found"]),
        .show(Show(machines: [Machine(name: "A", displays: 2)], works: [Work(name: "Smith")]), lengths: [60]),
    ]

    func testEveryMessageRoundTrips() throws {
        var r = LinkFraming.Reader()
        for m in messages { XCTAssertEqual(try r.feed(LinkFraming.frame(m)), [m]) }
    }

    /// TCP may cut anywhere: one byte at a time must still give each
    /// message exactly once, when its last byte arrives.
    func testAMessageSplitAcrossReads() throws {
        var r = LinkFraming.Reader()
        let bytes = try LinkFraming.frame(messages[1])
        var got: [LinkMessage] = []
        for b in bytes { got += try r.feed(Data([b])) }
        XCTAssertEqual(got, [messages[1]])
    }

    func testSeveralMessagesInOneRead() throws {
        var r = LinkFraming.Reader()
        let all = try messages.map(LinkFraming.frame).reduce(Data(), +)
        XCTAssertEqual(try r.feed(all), messages)
    }

    func testAnOversizeLengthIsRefused() {
        var r = LinkFraming.Reader()
        XCTAssertThrowsError(try r.feed(Data([0x7F, 0xFF, 0xFF, 0xFF]))) {
            XCTAssertEqual($0 as? LinkFraming.Failure, .tooLong(0x7FFF_FFFF))
        }
    }

    /// A frame that doesn't decode (from a newer build, say) is skipped and
    /// the stream stays in step for the next one.
    func testAnUnknownMessageIsSkippedNotFatal() throws {
        var r = LinkFraming.Reader()
        let junk = Data("{\"future\":{}}".utf8)
        let framed = Data([0, 0, 0, UInt8(junk.count)]) + junk + (try LinkFraming.frame(messages[0]))
        XCTAssertEqual(try r.feed(framed), [messages[0]])
        XCTAssertEqual(r.skipped, 1)
    }
}

final class SharedShowTests: XCTestCase {
    private func inv(_ machine: String, _ displays: Int, _ folders: [String: [(String, Double)]]) -> Inventory {
        Inventory(machine: machine, displays: displays,
                  folders: folders.mapValues { $0.map { InventoryFile(name: $0.0, duration: $0.1) } })
    }

    func testPlayersAreAddedInTheOrderTheyAreFirstHeardFrom() {
        var s = Show(machines: [Machine(name: "Conductor", displays: 2)])
        s = SharedShow.merge(s, with: inv("C", 1, [:]), conductor: "Conductor")
        s = SharedShow.merge(s, with: inv("B", 3, [:]), conductor: "Conductor")
        s = SharedShow.merge(s, with: inv("C", 2, [:]), conductor: "Conductor")   // heard again, with a display added
        XCTAssertEqual(s.machines.map(\.name), ["Conductor", "C", "B"])
        XCTAssertEqual(s.machines.map(\.displays), [2, 2, 3])
    }

    func testAPlayersFoldersJoinWorksByNameAndNewOnesAreAdded() {
        var s = Show(machines: [Machine(name: "A", displays: 1)],
                     works: [Work(name: "Smith", screens: ["A": [PanelConfig(file: "Smith/a.mp4")]], repeat: .times(2))])
        s = SharedShow.merge(s, with: inv("B", 2, ["Smith": [("2.mp4", 5), ("1.mp4", 5)], "Jones": [("1.mp4", 9)]]), conductor: "A")
        XCTAssertEqual(s.works.map(\.name), ["Smith", "Jones"])
        XCTAssertEqual(s.works[0].screens["B"]?.map(\.file), ["Smith/1.mp4", "Smith/2.mp4"])
        XCTAssertEqual(s.works[0].repeat, .times(2))                 // settings kept
        XCTAssertEqual(s.works[0].screens["A"]?.map(\.file), ["Smith/a.mp4"])
    }

    /// P4d: a saved show is curated. A player's folders the show doesn't name
    /// stay in the pool; works the show does name get the player's screens.
    func testASavedShowGainsScreensButNotWorks() {
        let s = Show(machines: [Machine(name: "A", displays: 1)], works: [Work(name: "Smith")])
        let m = SharedShow.merge(s, with: inv("B", 1, ["Smith": [("1.mp4", 5)], "Lee": [("1.mp4", 5)]]),
                                 conductor: "A", addingNewWorks: false)
        XCTAssertEqual(m.works.map(\.name), ["Smith"])
        XCTAssertEqual(m.works[0].screens["B"]?.map(\.file), ["Smith/1.mp4"])
        let all = SharedShow.merge(s, with: inv("B", 1, ["Lee": [("1.mp4", 5)]]), conductor: "A")
        XCTAssertEqual(all.works.map(\.name), ["Smith", "Lee"])                         // the all-works show grows
    }

    /// Mat (2026-10-22): a Mac reporting fewer displays than the show was
    /// designed for keeps the design's count and screens, so it can be
    /// previewed "as if"; reporting more grows it.
    func testADisplayCountIsTheDesignAndNeverShrinksByItself() {
        var s = Show(machines: [Machine(name: "A", displays: 1)],
                     works: [Work(name: "W", screens: ["B": [PanelConfig(file: "W/1.mp4"), PanelConfig(file: "W/2.mp4"), PanelConfig(file: "W/3.mp4")]])])
        s.machines.append(Machine(name: "B", displays: 3))
        let fewer = SharedShow.merge(s, with: inv("B", 1, ["W": [("1.mp4", 5), ("2.mp4", 5), ("3.mp4", 5)]]), conductor: "A")
        XCTAssertEqual(fewer.machines[1].displays, 3)
        XCTAssertEqual(fewer.works[0].screens["B"]?.count, 3)
        let more = SharedShow.merge(s, with: inv("B", 4, [:]), conductor: "A")
        XCTAssertEqual(more.machines[1].displays, 4)
    }

    func testAJoiningMacIsSizedByItsWorks() {
        let s = Show(machines: [Machine(name: "A", displays: 3)])
        let m = SharedShow.merge(s, with: inv("B", 1, ["W": [("W_4.mov", 5), ("W_5.mov", 5), ("W_6.mov", 5)]]), conductor: "A")
        XCTAssertEqual(m.machines[1].displays, 3)                    // screens 4–6, though only 1 is plugged in
        XCTAssertEqual(m.works[0].screens["B"]?.map(\.file), ["W/W_4.mov", "W/W_5.mov", "W/W_6.mov"])
    }

    func testHandSetScreensAreKeptAndNewDisplaysFill() {
        let set = [PanelConfig(file: "Smith/3.mp4", audio: true)]
        var s = Show(machines: [Machine(name: "A")], works: [Work(name: "Smith", screens: ["B": set])])
        s = SharedShow.merge(s, with: inv("B", 3, ["Smith": [("1.mp4", 5), ("2.mp4", 5), ("3.mp4", 5)]]), conductor: "A")
        XCTAssertEqual(s.works[0].screens["B"]?.map(\.file), ["Smith/3.mp4", "Smith/1.mp4", "Smith/2.mp4"])
        XCTAssertEqual(s.works[0].screens["B"]?[0].audio, true)
    }

    func testLengthIsTheLongestFileOnAnyMacIncludingTheConductor() {
        var s = Show(machines: [Machine(name: "A")],
                     works: [Work(name: "Smith"), Work(name: "Jones"), Work(name: "Empty")])
        let b = inv("B", 1, ["Smith": [("1.mp4", 40)], "Jones": [("1.mp4", 9)]])
        s = SharedShow.merge(s, with: b, conductor: "A")
        XCTAssertEqual(SharedShow.lengths(s, own: [60, 3], inventories: [b]), [60, 9, 0])
    }

    /// The bug the P4a loopback found: a one-Mac show saved under another
    /// name lost the conductor's part when the first player joined.
    func testAConductorAdoptsAOneMachineShowSavedElsewhere() {
        let s = Show(machines: [Machine(name: "Laptop", displays: 2)],
                     works: [Work(name: "Smith", screens: ["Laptop": [PanelConfig(file: "Smith/1.mp4")]])])
        let m = SharedShow.merge(s, with: inv("B", 1, [:]), conductor: "Mac mini")
        XCTAssertEqual(m.machines.map(\.name), ["Mac mini", "B"])
        XCTAssertEqual(m.machines[0].displays, 2)
        XCTAssertEqual(m.works[0].screens["Mac mini"]?.map(\.file), ["Smith/1.mp4"])
        XCTAssertNil(m.works[0].screens["Laptop"])
        XCTAssertEqual(m.machineIndex(named: "Mac mini"), 0)
    }

    /// …but a lone machine that IS the joining player stays the player's,
    /// and a show with several machines is never renamed.
    func testNoAdoptionOfThePlayersOwnPartOrOfASeveralMachineShow() {
        let mine = Show(machines: [Machine(name: "B", displays: 1)])
        XCTAssertEqual(SharedShow.merge(mine, with: inv("B", 1, [:]), conductor: "A").machines.map(\.name), ["B"])
        let two = Show(machines: [Machine(name: "X"), Machine(name: "Y")])
        XCTAssertEqual(SharedShow.merge(two, with: inv("B", 1, [:]), conductor: "A").machines.map(\.name), ["X", "Y", "B"])
    }
}
