import XCTest
@testable import PlayerCore

/// [claude] Collecting and importing (docs/architecture.md § v4 › Collecting
/// and importing).
final class CollectTests: XCTestCase {
    private func resolve(_ f: String) -> String { f.hasPrefix("/") ? f : "/Media/" + f }
    private func panel(_ f: String?, audio: Bool = false) -> PanelConfig { PanelConfig(file: f, audio: audio) }

    func testThisMacsPanelsPointAtCopiesRelativeToTheArchive() {
        let w = Work(name: "Smith", screens: ["A": [panel("Smith/1.mp4", audio: true), panel(nil), panel("/Users/x/Desktop/2.mov")]],
                     repeat: .times(2), shorter: .loop)
        let p = Collect.plan(works: [w], machine: "A", resolve: resolve)
        // Screen 2 is black, which a scan of "1.mp4, 2.mov" wouldn't keep, so
        // the copies are named for their screens (Mat's "_N", 2026-10-22).
        XCTAssertEqual(p.copies, [.init(source: "/Media/Smith/1.mp4", dest: "Smith/1_1.mp4"),
                                  .init(source: "/Users/x/Desktop/2.mov", dest: "Smith/2_3.mov")])
        XCTAssertEqual(p.works[0].screens["A"]?.map(\.file), ["Smith/1_1.mp4", nil, "Smith/2_3.mov"])
        // Everything but the paths is kept.
        XCTAssertEqual(p.works[0].screens["A"]?[0].audio, true)
        XCTAssertEqual(p.works[0].repeat, .times(2))
        XCTAssertEqual(p.works[0].shorter, .loop)
    }

    func testOtherMacsAreLeftAlone() {
        let w = Work(name: "W", screens: ["A": [panel("W/1.mp4")], "B": [panel("/Volumes/B/9.mp4")]])
        let p = Collect.plan(works: [w], machine: "A", resolve: resolve)
        XCTAssertEqual(p.works[0].screens["B"], w.screens["B"])
        XCTAssertEqual(p.copies.count, 1)
    }

    func testAWorkWithNothingOnThisMacCopiesNothing() {
        let w = Work(name: "W", screens: ["B": [panel("W/1.mp4")]])
        let p = Collect.plan(works: [w], machine: "A", resolve: resolve)
        XCTAssertEqual(p.copies, [])
        XCTAssertEqual(p.works, [w])
    }

    func testOneFileOnTwoScreensIsCopiedOnce() {
        let w = Work(name: "W", screens: ["A": [panel("W/1.mp4"), panel("W/1.mp4")]])
        let p = Collect.plan(works: [w], machine: "A", resolve: resolve)
        // Named for its first screen; the show file keeps it on both.
        XCTAssertEqual(p.copies.map(\.dest), ["W/1_1.mp4"])
        XCTAssertEqual(p.works[0].screens["A"]?.map(\.file), ["W/1_1.mp4", "W/1_1.mp4"])
    }

    func testSameNameFromTwoPlacesGetsANumberIgnoringCase() {
        let w = Work(name: "W", screens: ["A": [panel("/a/Clip.mp4"), panel("/b/clip.mp4"), panel("/c/clip.mp4")]])
        let p = Collect.plan(works: [w], machine: "A", resolve: resolve)
        // "clip 2" sorts before "Clip" (a space before a dot), so name order
        // wouldn't restore the screens: numbered too.
        XCTAssertEqual(p.copies.map(\.dest), ["W/Clip_1.mp4", "W/clip 2_2.mp4", "W/clip 3_3.mp4"])
        XCTAssertEqual(p.works[0].screens["A"]?.map(\.file), ["W/Clip_1.mp4", "W/clip 2_2.mp4", "W/clip 3_3.mp4"])
    }

    /// When a scan of the names would put them back the same, names are kept.
    func testNamesAreKeptWhenTheScanWouldRestoreThem() {
        let w = Work(name: "W", screens: ["A": [panel("W/a.mp4"), panel("W/b.mp4")]])
        XCTAssertEqual(Collect.plan(works: [w], machine: "A", resolve: resolve).copies.map(\.dest), ["W/a.mp4", "W/b.mp4"])
    }

    /// A Mac whose screens start at 4 (after a 3-display Mac) numbers 4, 5…;
    /// a file already carrying its right number keeps its name.
    func testNumbersCountAcrossTheTableau() {
        let w = Work(name: "W", screens: ["B": [panel("W/x_4.mov"), panel(nil), panel("W/y.mov")]])
        let p = Collect.plan(works: [w], machine: "B", resolve: resolve, firstScreen: 4)
        XCTAssertEqual(p.copies.map(\.dest), ["W/x_4.mov", "W/y_6.mov"])
    }

    /// The point of it: collect, then scan the archive, gives the same screens.
    func testANumberedArchiveScansBackToTheSameScreens() {
        let panels = [panel("/s/intro.mov"), panel(nil), panel("/s/end.mov")]
        let p = Collect.plan(works: [Work(name: "W", screens: ["A": panels])], machine: "A", resolve: resolve)
        let names = p.copies.map { ($0.dest as NSString).lastPathComponent }
        XCTAssertEqual(FolderScan.assign(folder: "W", files: names, displays: 3).panels.map(\.file),
                       p.works[0].screens["A"]?.map(\.file))
    }

    func testUnsafeAndRepeatedWorkNamesGetSafeDistinctFolders() {
        let works = [Work(name: "A/B: C", screens: ["M": [panel("x/1.mp4")]]),
                     Work(name: ".hidden", screens: ["M": [panel("x/2.mp4")]]),
                     Work(name: "Same", screens: ["M": [panel("x/3.mp4")]]),
                     Work(name: "same", screens: ["M": [panel("x/4.mp4")]])]
        let p = Collect.plan(works: works, machine: "M", resolve: resolve)
        XCTAssertEqual(p.copies.map(\.dest), ["A-B- C/1.mp4", "hidden/2.mp4", "Same/3.mp4", "same 2/4.mp4"])
        // The work's own name is kept: it joins the work across Macs.
        XCTAssertEqual(p.works.map(\.name), works.map(\.name))
    }

    func testAWorkFolderAvoidsNamesAlreadyInTheDestination() {
        let w = Work(name: "Smith", screens: ["M": [panel("x/1.mp4")]])
        let p = Collect.plan(works: [w], machine: "M", resolve: resolve, takenFolders: ["smith"])
        XCTAssertEqual(p.copies.map(\.dest), ["Smith 2/1.mp4"])
    }

    func testUniqueNameWithoutExtension() {
        XCTAssertEqual(Collect.uniqueName("W", taken: ["w", "w 2"]), "W 3")
        XCTAssertEqual(Collect.folderName("  "), "Untitled")
    }
}

final class FolderImportTests: XCTestCase {
    func testRootVideosAndSubfoldersBecomeWorksWithFullPaths() {
        let r = FolderImport.works(root: "/Class/Smith", rootFiles: ["2.mp4", "1.mp4", "notes.txt"],
                                   subfolders: ["10 Extra": ["a.mov"], "2 Jones": ["b.mp4"], "Empty": ["x.txt"], ".git": ["c.mp4"]],
                                   machine: "M", displays: 2, existing: [])
        XCTAssertEqual(r.works.map(\.name), ["Smith", "2 Jones", "10 Extra"])
        XCTAssertEqual(r.works[0].screens["M"]?.map(\.file), ["/Class/Smith/1.mp4", "/Class/Smith/2.mp4"])
        XCTAssertEqual(r.works[1].screens["M"]?.map(\.file), ["/Class/Smith/2 Jones/b.mp4", nil])
        XCTAssertEqual(r.works[0].repeat, .once)          // a new work's defaults
        XCTAssertEqual(r.skipped, [])
    }

    func testNamesAlreadyInThePlaylistAreSkipped() {
        let r = FolderImport.works(root: "/x/Archive", rootFiles: [], subfolders: ["Smith": ["1.mp4"], "Jones": ["1.mp4"]],
                                   machine: "M", displays: 1, existing: ["Smith"])
        XCTAssertEqual(r.works.map(\.name), ["Jones"])
        XCTAssertEqual(r.skipped, ["Smith"])
    }

    func testFilesBeyondTheDisplaysAreLeftOver() {
        let r = FolderImport.works(root: "/x/W", rootFiles: ["1.mp4", "2.mp4", "3.mp4"], subfolders: [:],
                                   machine: "M", displays: 2, existing: [])
        XCTAssertEqual(r.leftOver, ["W": ["3.mp4"]])
    }

    /// The archive round trip: what Collect writes, Import reads back as the
    /// same works with the same screens.
    func testACollectedArchiveImportsBack() {
        let works = [Work(name: "Smith", screens: ["M": [PanelConfig(file: "/a/1.mp4"), PanelConfig(file: "/b/2.mp4")]])]
        let plan = Collect.plan(works: works, machine: "M", resolve: { $0 })
        var listing: [String: [String]] = [:]
        for c in plan.copies {
            listing[(c.dest as NSString).deletingLastPathComponent, default: []].append((c.dest as NSString).lastPathComponent)
        }
        let r = FolderImport.works(root: "/Archive", rootFiles: ["Show.tableaux"], subfolders: listing,
                                   machine: "M", displays: 2, existing: [])
        XCTAssertEqual(r.works[0].screens["M"]?.map(\.file), plan.works[0].screens["M"]?.map { $0.file.map { "/Archive/" + $0 } })
    }
}
