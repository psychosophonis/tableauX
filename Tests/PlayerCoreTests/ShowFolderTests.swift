import XCTest
@testable import PlayerCore

/// [claude] v4 P4b, zero setup (docs/architecture.md § v4 › Zero setup).
final class ShowFolderTests: XCTestCase {
    private typealias Listing = (files: [String], subfolders: [String: [String]])

    private func disk(_ folders: [String: Listing]) -> (String) -> Listing? { { folders[$0] } }

    func testTheAppsOwnFolderWinsWhenItHoldsAShowOrWorks() {
        let d = disk(["/Vol/Show": (["tableauX.app"], ["Smith": ["1.mp4"]]),
                      "/Users/m/tableauX": ([], [:])])
        XCTAssertEqual(ShowFolder.pick(chosen: nil, appFolder: "/Vol/Show", home: "/Users/m", listing: d), "/Vol/Show")
    }

    /// An app in /Applications (or Downloads) must not adopt that folder.
    func testTheAppsFolderIsSkippedWhenItIsNotAShowFolder() {
        let d = disk(["/Applications": (["tableauX.app", "Safari.app"], ["Utilities": ["x.app"]]),
                      "/Users/m/Movies/tableauX": ([], [:])])
        XCTAssertEqual(ShowFolder.pick(chosen: nil, appFolder: "/Applications", home: "/Users/m", listing: d),
                       "/Users/m/Movies/tableauX")
    }

    /// Mat's layout: the app and a tableauX folder side by side.
    func testATableauXFolderBesideTheAppIsFound() {
        let d = disk(["/Volumes/E/testshow": ([], ["tableauX": ["work1", "work2"]]),
                      "/Volumes/E/testshow/tableauX": ([], ["work1": ["Comp 4_1.mov"]]),
                      "/Users/m/tableauX": ([], [:])])
        XCTAssertEqual(ShowFolder.pick(chosen: nil, appFolder: "/Volumes/E/testshow", home: "/Users/m", listing: d),
                       "/Volumes/E/testshow/tableauX")
    }

    func testHomeThenMoviesThenDesktop() {
        let both = disk(["/Users/m/Desktop/tableauX": ([], [:]), "/Users/m/tableauX": ([], [:])])
        XCTAssertEqual(ShowFolder.pick(chosen: nil, appFolder: nil, home: "/Users/m", listing: both), "/Users/m/tableauX")
        let desk = disk(["/Users/m/Desktop/tableauX": ([], [:])])
        XCTAssertEqual(ShowFolder.pick(chosen: nil, appFolder: nil, home: "/Users/m", listing: desk), "/Users/m/Desktop/tableauX")
        XCTAssertNil(ShowFolder.pick(chosen: nil, appFolder: nil, home: "/Users/m", listing: disk([:])))
    }

    func testAFolderChosenByHandWinsWhileItExists() {
        let d = disk(["/Vol/Show": (["a.tableaux"], [:]), "/Users/m/Class": ([], [:])])
        XCTAssertEqual(ShowFolder.pick(chosen: "/Users/m/Class", appFolder: "/Vol/Show", home: "/Users/m", listing: d), "/Users/m/Class")
        XCTAssertEqual(ShowFolder.pick(chosen: "/gone", appFolder: "/Vol/Show", home: "/Users/m", listing: d), "/Vol/Show")
    }

    func testAShowFileOrAWorkFolderMakesAShowFolder() {
        XCTAssertTrue(ShowFolder.isShowFolder(files: ["Class.TABLEAUX"], subfolders: [:]))
        XCTAssertTrue(ShowFolder.isShowFolder(files: [], subfolders: ["Smith": ["1.mov"]]))
        XCTAssertFalse(ShowFolder.isShowFolder(files: ["notes.txt"], subfolders: ["Empty": ["a.txt"], ".hidden": ["1.mp4"]]))
        XCTAssertEqual(ShowFolder.shows(in: ["a.tableaux", ".b.tableaux", "c.mp4"]), ["a.tableaux"])
    }

    // P4d, the library.

    func testALibraryKeepsWorksAndShowsApartALegacyFolderIsBoth() {
        XCTAssertEqual(ShowFolder.layout(root: "/L", subfolders: ["Works", "Shows"]).works, "/L/Works")
        XCTAssertEqual(ShowFolder.layout(root: "/L", subfolders: ["works"]).shows, "/L/Shows")      // Shows made when first saved
        let legacy = ShowFolder.layout(root: "/L", subfolders: ["Smith", "Jones"])
        XCTAssertEqual(legacy.works, "/L")
        XCTAssertEqual(legacy.shows, "/L")
    }

    func testALibraryRootCountsAsAShowFolder() {
        XCTAssertTrue(ShowFolder.isShowFolder(files: [], subfolders: ["Works": ["Smith"]]))
        XCTAssertTrue(ShowFolder.isShowFolder(files: [], subfolders: ["Shows": ["a.tableaux"]]))
    }

    func testThePoolIsEveryMacsWorksOnceInNameOrder() {
        let inv = Inventory(machine: "B", displays: 1, folders: ["Lee": [], "Smith": []])
        XCTAssertEqual(ShowFolder.pool(own: ["Smith", "Jones", ".git"], inventories: [inv]), ["Jones", "Lee", "Smith"])
    }

    func testWhichShowOpensAtLaunch() {
        let shows = [(path: "/F/old.tableaux", modified: 1.0), (path: "/F/new.tableaux", modified: 2.0)]
        XCTAssertEqual(ShowFolder.showToOpen(last: "/F/old.tableaux", folder: "/F", folderChosen: false, folderShows: shows), "/F/old.tableaux")
        XCTAssertEqual(ShowFolder.showToOpen(last: "/Elsewhere/x.tableaux", folder: "/F", folderChosen: false, folderShows: shows), "/F/new.tableaux")
        XCTAssertEqual(ShowFolder.showToOpen(last: "/Elsewhere/x.tableaux", folder: "/F", folderChosen: true, folderShows: []), "/Elsewhere/x.tableaux")
        XCTAssertEqual(ShowFolder.showToOpen(last: "/Elsewhere/x.tableaux", folder: nil, folderChosen: false, folderShows: []), "/Elsewhere/x.tableaux")
        XCTAssertNil(ShowFolder.showToOpen(last: nil, folder: nil, folderChosen: false, folderShows: []))
    }

    /// Mat's run (2026-10-22): the app in a folder of works with no show
    /// file, after the test kit's show had been opened elsewhere. The old
    /// rule reopened that show against this folder (every file missing).
    func testAFoundFolderWithNoShowStartsFreshNotWithAShowFromElsewhere() {
        XCTAssertNil(ShowFolder.showToOpen(last: "/Desktop/kit/Test show.tableaux", folder: "/Volumes/E/testshow",
                                           folderChosen: false, folderShows: []))
    }
}
