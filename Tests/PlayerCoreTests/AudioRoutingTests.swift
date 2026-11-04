import XCTest
@testable import PlayerCore

/// [claude] v5: docs/architecture.md § A stereo file meant for one speaker,
/// § Getting sound in, § Output device.
final class AudioRoutingTests: XCTestCase {
    private func stereo(_ kind: StereoKind) -> AudioFacts { AudioFacts(channels: 2, duration: 10, stereo: kind) }
    private let mono = AudioFacts(channels: 1, duration: 10)
    private func route(_ output: Int, _ take: AudioTake = .auto) -> AudioRoute {
        AudioRoute(file: "W/audio/\(output).wav", output: output, take: take)
    }

    // MARK: Reading a stereo file. The levels are those measured by
    // proofs/audio-decode-probe.swift, as dB of L−R relative to the signal.

    private func level(_ dB: Double) -> Double { pow(10, dB / 20) }

    func testDualMonoThroughCommonEncodersReadsAsDual() {
        for dB in [-200.0, -61.7, -43.5] {
            XCTAssertEqual(AudioRouting.classify(left: 0.1, right: 0.1, difference: 0.1 * level(dB)), .dual, "\(dB) dB")
        }
    }

    func testTheClosestRealStereoMeasuredStaysStereo() {
        for dB in [-39.1, -25.8, -15.3, 2.9] {
            XCTAssertEqual(AudioRouting.classify(left: 0.1, right: 0.1, difference: 0.1 * level(dB)), .different, "\(dB) dB")
        }
    }

    /// A known failure, kept in the open: pure noise through ffmpeg's AAC. This is
    /// why the reading is only a default and each route can be set by hand.
    func testDualMonoNoiseThroughFfmpegAACIsMisreadAsStereo() {
        XCTAssertEqual(AudioRouting.classify(left: 0.06, right: 0.06, difference: 0.06 * level(-13.2)), .different)
    }

    func testOneSidedAndSilentFiles() {
        XCTAssertEqual(AudioRouting.classify(left: 0.1, right: 0, difference: 0.1), .leftOnly)
        XCTAssertEqual(AudioRouting.classify(left: 0, right: 0.1, difference: 0.1), .rightOnly)
        XCTAssertEqual(AudioRouting.classify(left: 0, right: 0, difference: 0), .silent)
    }

    // MARK: Routing

    func testDualMonoAndOneSidedFilesTakeOneSpeaker() {
        let p = AudioRouting.plan(routes: [route(1), route(2), route(3)],
                                  facts: [stereo(.dual), stereo(.leftOnly), stereo(.rightOnly)])
        XCTAssertEqual(p.feeds, [.init(output: 1, source: 0, channels: [0]),
                                 .init(output: 2, source: 1, channels: [0]),
                                 .init(output: 3, source: 2, channels: [1])])
        XCTAssertTrue(p.problems.isEmpty)
    }

    func testRealStereoWithTheNextOutputFreeIsAPair() {
        let p = AudioRouting.plan(routes: [route(9)], facts: [stereo(.different)])
        XCTAssertEqual(p.feeds, [.init(output: 9, source: 0, channels: [0]), .init(output: 10, source: 0, channels: [1])])
        XCTAssertEqual(p.outputs, 10)
    }

    /// Mat's case: a student's array of stereo exports, one per speaker.
    func testAnArrayOfStereoFilesIsOneSpeakerEachWhateverTheirOrder() {
        for order in [[1, 2, 3, 4], [4, 2, 3, 1]] {
            let p = AudioRouting.plan(routes: order.map { route($0) }, facts: order.map { _ in stereo(.different) })
            XCTAssertEqual(p.feeds.map(\.output), [1, 2, 3, 4], "nothing leaks onto output 5: \(order)")
            XCTAssertTrue(p.feeds.allSatisfy { $0.channels == [0, 1] }, "all summed: \(order)")
            XCTAssertTrue(p.problems.isEmpty, "\(p.problems)")
        }
    }

    /// Stereo per screen: 1, 3, 5 leave every pair's second output free.
    func testStereoPerScreen() {
        let p = AudioRouting.plan(routes: [route(1), route(3), route(5)], facts: Array(repeating: stereo(.different), count: 3))
        XCTAssertEqual(p.feeds.map(\.output), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(p.feeds.map(\.source), [0, 0, 1, 1, 2, 2])
    }

    func testAPersonOverrulesTheReading() {
        let facts = [stereo(.dual)]
        XCTAssertEqual(AudioRouting.plan(routes: [route(1, .pair)], facts: facts).feeds.map(\.output), [1, 2])
        XCTAssertEqual(AudioRouting.plan(routes: [route(1, .right)], facts: facts).feeds, [.init(output: 1, source: 0, channels: [1])])
        let diff = [stereo(.different)]
        XCTAssertEqual(AudioRouting.plan(routes: [route(1, .sum)], facts: diff).feeds, [.init(output: 1, source: 0, channels: [0, 1])])
        XCTAssertEqual(AudioRouting.plan(routes: [route(1, .left)], facts: diff).feeds, [.init(output: 1, source: 0, channels: [0])])
    }

    func testEveryDecisionSaysWhy() {
        let p = AudioRouting.plan(routes: [route(1), route(3)], facts: [stereo(.dual), stereo(.different)])
        XCTAssertTrue(p.lines[0].contains("one speaker"), p.lines[0])
        XCTAssertTrue(p.lines[1].contains("Outputs 3–4"), p.lines[1])
    }

    func testTwoSourcesOnOneOutputIsAProblemNotAMix() {
        XCTAssertFalse(AudioRouting.plan(routes: [route(1), route(1)], facts: [mono, mono]).problems.isEmpty)
        // A span reaching another source's output is the same mistake.
        let six = AudioFacts(channels: 6, duration: 10)
        XCTAssertFalse(AudioRouting.plan(routes: [route(1), route(3)], facts: [six, mono]).problems.isEmpty)
    }

    func testAManyChannelFileTakesOutputsInOrder() {
        let p = AudioRouting.plan(routes: [route(3)], facts: [AudioFacts(channels: 6, duration: 10)])
        XCTAssertEqual(p.feeds.map(\.output), [3, 4, 5, 6, 7, 8])
        XCTAssertEqual(p.feeds.map(\.channels), (0..<6).map { [$0] })
    }

    func testOneMonoFileStillBakesTwoChannels() {
        XCTAssertEqual(AudioRouting.plan(routes: [route(1)], facts: [mono]).outputs, 2)
    }

    /// Off is how a file in the folder is silenced: removing its route would only
    /// bring it back on the next rescan.
    func testOutputZeroIsOffAndARescanLeavesItOff() throws {
        let off = AudioRoute(file: "W/audio/a.wav", output: 0)
        let p = AudioRouting.plan(routes: [off], facts: [mono])
        XCTAssertTrue(p.feeds.isEmpty)
        XCTAssertTrue(p.problems.isEmpty)
        XCTAssertEqual(p.lines, ["Off"])
        XCTAssertEqual(AudioScan.routes(existing: [off], folder: "W", names: ["a.wav"]), [off])
    }

    func testAnUnmeasuredSourceMakesThePlanIncomplete() {
        XCTAssertTrue(AudioRouting.plan(routes: [route(1)], facts: [nil]).incomplete)
    }

    func testAVideoWithNoSoundWarnsAndFeedsNothing() {
        let p = AudioRouting.plan(routes: [AudioRoute(screen: 1, output: 1)], facts: [AudioFacts(channels: 0)])
        XCTAssertTrue(p.feeds.isEmpty)
        XCTAssertEqual(p.outputs, 0)
        XCTAssertTrue(p.warnings[0].contains("Screen 2's video"), p.warnings[0])
    }

    func testLengthsAndRates() {
        let p = AudioRouting.plan(routes: [route(1), route(2)],
                                  facts: [AudioFacts(channels: 1, sampleRate: 44100, duration: 10),
                                          AudioFacts(channels: 1, sampleRate: 48000, duration: 10.01)])
        XCTAssertEqual(p.sampleRate, 48000)
        XCTAssertEqual(p.length, 10.01)
        XCTAssertTrue(p.warnings.isEmpty, "within a frame")
        let far = AudioRouting.plan(routes: [route(1), route(2)],
                                    facts: [AudioFacts(channels: 1, duration: 10), AudioFacts(channels: 1, duration: 12)])
        XCTAssertEqual(far.warnings.count, 1)
    }

    // MARK: Finding files

    func testScanNumbersAndFillsLowestFree() throws {
        let r = try XCTUnwrap(AudioScan.routes(existing: nil, folder: "W", names: ["a.wav", "front_2.wav", "b.wav", ".DS_Store", "notes.txt"]))
        XCTAssertEqual(r.map(\.file), ["W/audio/front_2.wav", "W/audio/a.wav", "W/audio/b.wav"])
        XCTAssertEqual(r.map(\.output), [2, 1, 3])
    }

    func testARescanKeepsWhatAPersonSet() throws {
        let set = [AudioRoute(file: "W/audio/a.wav", output: 7, take: .sum), AudioRoute(screen: 0, output: 1)]
        let r = try XCTUnwrap(AudioScan.routes(existing: set, folder: "W", names: ["a.wav", "b.wav"]))
        XCTAssertEqual(Array(r.prefix(2)), set)
        XCTAssertEqual(r[2], AudioRoute(file: "W/audio/b.wav", output: 2))
        XCTAssertEqual(AudioScan.routes(existing: r, folder: "W", names: ["a.wav", "b.wav"]), r, "nothing new, nothing changes")
    }

    func testNumberedFileAskingForATakenOutputFallsBackToLowestFree() throws {
        let r = try XCTUnwrap(AudioScan.routes(existing: [AudioRoute(file: "W/audio/a.wav", output: 3)], folder: "W", names: ["a.wav", "b_3.wav"]))
        XCTAssertEqual(r[1].output, 1)
    }

    func testNothingToRoute() {
        XCTAssertNil(AudioScan.routes(existing: nil, folder: "W", names: ["a.mov"]))
    }

    /// Mat's compose-ahead rule: subfolder per Mac, loose files are this Mac's.
    func testPerMacSubfolders() {
        let names = ["here_1.wav", "Gallery 2/a_1.wav", "Gallery 3/b_1.wav"]
        XCTAssertEqual(AudioScan.own(names, machine: "MacBook"), ["here_1.wav"])
        XCTAssertEqual(AudioScan.own(names, machine: "Lab Mini", label: "Gallery 2"), ["Gallery 2/a_1.wav"])
        XCTAssertEqual(AudioScan.own(names, machine: "Gallery 3"), ["Gallery 3/b_1.wav"])
    }

    // MARK: The show, the link, and archives keep a Mac's sound

    private let mine = [AudioRoute(file: "W/audio/a_1.wav", output: 1), AudioRoute(screen: 0, output: 3, take: .sum)]

    func testAShowWithoutSoundWritesNoAudioKeyAndOldFilesOpen() throws {
        let plain = Show(machines: [Machine(name: "A", displays: 1)], works: [Work(name: "W")])
        let json = String(decoding: try ShowFile.encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("audio\" :"), "the file is unchanged for a show that doesn't use sound: \(json)")
        XCTAssertNil(try ShowFile.decode(try ShowFile.encode(plain)).works[0].audio)
    }

    func testRoutesRoundTripThroughTheShowFile() throws {
        var w = Work(name: "W")
        w.setRoutes(mine, on: "A")
        let show = Show(machines: [Machine(name: "A", displays: 1)], works: [w])
        XCTAssertEqual(try ShowFile.decode(try ShowFile.encode(show)), show)
    }

    func testClearingTheLastRouteLeavesAudioNil() {
        var w = Work(name: "W")
        w.setRoutes(mine, on: "A")
        w.setRoutes([], on: "A")
        XCTAssertNil(w.audio)
    }

    func testRoutesFollowAMacClaimedOrAdoptedAndGoWhenItIsRemoved() {
        var w = Work(name: "W")
        w.setRoutes(mine, on: "Gallery 2")
        let show = Show(machines: [Machine(name: "A", displays: 1), Machine(name: "Gallery 2", displays: 1, label: "Gallery 2")], works: [w])
        XCTAssertEqual(show.claimingMachine("Gallery 2", as: "Lab Mini").works[0].routes(on: "Lab Mini"), mine)
        XCTAssertNil(show.removingMachine("Gallery 2").works[0].audio)

        var lone = Work(name: "W")
        lone.setRoutes(mine, on: "Old")
        let adopted = SharedShow.merge(Show(machines: [Machine(name: "Old", displays: 1)], works: [lone]),
                                       with: Inventory(machine: "P", displays: 1, folders: [:]), conductor: "C")
        XCTAssertEqual(adopted.works[0].routes(on: "C"), mine)
    }

    func testAPlayersSoundBecomesRoutesByItsLabelAndCountsInTheLength() {
        let show = Show(machines: [Machine(name: "C", displays: 1), Machine(name: "Mini", displays: 1, label: "Gallery 2")], works: [Work(name: "W")])
        let inv = Inventory(machine: "Mini", displays: 1, folders: ["W": []],
                            audio: ["W": [InventoryFile(name: "Gallery 2/a_4.wav", duration: 90), InventoryFile(name: "Gallery 3/b.wav", duration: 500)]])
        let merged = SharedShow.merge(show, with: inv, conductor: "C", addingNewWorks: false)
        XCTAssertEqual(merged.works[0].routes(on: "Mini"), [AudioRoute(file: "W/audio/Gallery 2/a_4.wav", output: 4)])
        XCTAssertEqual(PlaylistMerge.length(of: merged.works[0], in: [inv]), 90, "another Mac's subfolder doesn't count")
    }

    func testAPlayersOwnEditIsRecordedAndUnknownNamesChangeNothing() {
        let show = Show(machines: [Machine(name: "P", displays: 1)], works: [Work(name: "W")])
        XCTAssertEqual(SharedShow.setAudio(show, machine: "P", work: "W", routes: mine).works[0].routes(on: "P"), mine)
        XCTAssertEqual(SharedShow.setAudio(show, machine: "Q", work: "W", routes: mine), show)
        XCTAssertEqual(SharedShow.setAudio(show, machine: "P", work: "X", routes: mine), show)
    }

    func testTheSetAudioMessageRoundTrips() throws {
        var reader = LinkFraming.Reader()
        let m = LinkMessage.setAudio(machine: "P", work: "W", routes: mine)
        XCTAssertEqual(try reader.feed(LinkFraming.frame(m)), [m])
    }

    func testCollectCopiesSoundFilesAndRewritesRoutes() {
        var w = Work(name: "W", screens: ["A": [PanelConfig(file: "W/v.mov")]])
        w.setRoutes([AudioRoute(file: "W/audio/a_1.wav", output: 1, take: .sum), AudioRoute(screen: 0, output: 2)], on: "A")
        let p = Collect.plan(works: [w], machine: "A", resolve: { "/lib/" + $0 })
        XCTAssertTrue(p.copies.contains(.init(source: "/lib/W/audio/a_1.wav", dest: "W/audio/a_1.wav")))
        XCTAssertEqual(p.works[0].routes(on: "A")[0], AudioRoute(file: "W/audio/a_1.wav", output: 1, take: .sum))
        XCTAssertEqual(p.works[0].routes(on: "A")[1], AudioRoute(screen: 0, output: 2), "a screen's route has no file of its own")
    }

    func testGatherBringsALinkedSoundFileIntoTheWorksAudioFolder() {
        var w = Work(name: "W", screens: ["A": [PanelConfig(file: "W/v.mov")]])
        w.setRoutes([AudioRoute(file: "/Volumes/USB/b_2.wav", output: 2)], on: "A")
        let p = Collect.gather(works: [w], machine: "A", worksFolder: "/lib", folders: ["W"], listing: { _ in [] })
        XCTAssertEqual(p.copies, [.init(source: "/Volumes/USB/b_2.wav", dest: "W/audio/b_2.wav")])
        XCTAssertEqual(p.works[0].routes(on: "A")[0].file, "W/audio/b_2.wav")
    }

    func testAKitCarriesOnlyThatMacsSoundAtItsLibraryPath() {
        var w = Work(name: "W", screens: ["A": [PanelConfig(file: "W/a.mov")], "B": [PanelConfig(file: "W/b.mov")]])
        w.setRoutes([AudioRoute(file: "W/audio/A/x_1.wav", output: 1)], on: "A")
        w.setRoutes([AudioRoute(file: "W/audio/B/y_1.wav", output: 1), AudioRoute(file: "/Volumes/U/z.wav", output: 2)], on: "B")
        let show = Show(machines: [Machine(name: "A", displays: 1), Machine(name: "B", displays: 1)], works: [w])
        let kits = Kits.plan(show: show, conductor: nil, resolve: { "/lib/" + $0 })
        let b = kits.first { $0.machine == "B" }
        XCTAssertEqual(b?.copies.map(\.dest), ["W/b.mov", "W/audio/B/y_1.wav"])
        XCTAssertEqual(b?.linked, ["/Volumes/U/z.wav"])
    }

    // MARK: Stereo fold-down

    func testEqualPowerPan() {
        for pan in stride(from: -1.0, through: 1.0, by: 0.25) {
            let (l, r) = AudioRouting.panGains(pan)
            XCTAssertEqual(l * l + r * r, 1, accuracy: 1e-9, "power is the same at \(pan)")
        }
        XCTAssertEqual(AudioRouting.panGains(-1).left, 1, accuracy: 1e-9)
        XCTAssertEqual(AudioRouting.panGains(-1).right, 0, accuracy: 1e-9)
        XCTAssertEqual(AudioRouting.panGains(1).right, 1, accuracy: 1e-9)
        XCTAssertEqual(AudioRouting.panGains(0).left, 0.5.squareRoot(), accuracy: 1e-9)
    }

    func testOddOutputsStartLeftAndEvenRight() {
        let m = Machine(name: "A")
        XCTAssertEqual(m.pan(of: 1), -1)
        XCTAssertEqual(m.pan(of: 2), 1)
        XCTAssertEqual(m.pan(of: 7), -1)
    }

    func testPansSetAndUnsetAndTheDefaultIsNotStored() throws {
        var m = Machine(name: "A")
        m.setPan(0.25, of: 3)
        XCTAssertEqual(m.pan(of: 3), 0.25)
        m.setPan(5, of: 4)
        XCTAssertEqual(m.pan(of: 4), 1, "clamped, and 1 is output 4's default")
        m.setPan(-1, of: 3)
        XCTAssertNil(m.pans, "back at the default, so nothing is stored")
    }

    func testPansRoundTripAndOldFilesOpen() throws {
        var m = Machine(name: "A", displays: 1)
        m.setPan(-0.5, of: 2)
        let show = Show(machines: [m])
        XCTAssertEqual(try ShowFile.decode(try ShowFile.encode(show)), show)
        let plain = String(decoding: try ShowFile.encode(Show(machines: [Machine(name: "A", displays: 1)])), as: UTF8.self)
        XCTAssertFalse(plain.contains("pans"))
    }

    func testAFoldKeepsTheSpeakerDecisionsAndPans() {
        let plan = AudioRouting.plan(routes: [route(1), route(2), route(7)], facts: [stereo(.dual), mono, stereo(.different)])
        let fold = AudioRouting.fold([.init(plan: plan, sources: 3, pan: { $0 == 8 ? 0 : Machine(name: "A").pan(of: $0) })])
        XCTAssertEqual(fold.outputs, 2)
        XCTAssertEqual(fold.feeds.filter { $0.output == 1 }.map(\.source), [0, 2, 2], "dual mono once, stereo 7 hard left, 8 centred")
        XCTAssertEqual(fold.feeds.filter { $0.output == 2 }.map(\.source), [1, 2])
        XCTAssertEqual(fold.feeds.first { $0.output == 2 && $0.source == 2 }?.gain ?? 0, 0.5.squareRoot(), accuracy: 1e-9)
    }

    /// Mat's array across Macs, heard from one: output 1 on each is its own speaker.
    func testAFoldAcrossMacsNumbersSourcesInTurnAndUsesEachMacsPans() {
        let a = AudioRouting.plan(routes: [route(1), route(2)], facts: [mono, mono])
        let b = AudioRouting.plan(routes: [route(1)], facts: [AudioFacts(channels: 1, sampleRate: 96000, duration: 20)])
        let fold = AudioRouting.fold([.init(plan: a, sources: 2, pan: { _ in -1 }), .init(plan: b, sources: 1, pan: { _ in 1 })])
        XCTAssertEqual(fold.feeds.filter { $0.output == 1 }.map(\.source), [0, 1])
        XCTAssertEqual(fold.feeds.filter { $0.output == 2 }.map(\.source), [2])
        XCTAssertEqual(fold.sampleRate, 96000)
        XCTAssertEqual(fold.length, 20)
    }

    func testAFoldOfNothingNeedsNoOutputs() {
        XCTAssertEqual(AudioRouting.fold([]).outputs, 0)
    }

    func testAMacComposedAheadGetsItsSubfolderAndNeverTheLooseFiles() throws {
        let names = ["here_1.wav", "Gallery 2/a_3.wav", "Gallery 3/b_1.wav"]
        XCTAssertEqual(AudioScan.subfolderOnly(names, machine: "Gallery 2"), ["Gallery 2/a_3.wav"])
        XCTAssertEqual(AudioScan.subfolderOnly(names, machine: "Mini", label: "Gallery 3"), ["Gallery 3/b_1.wav"])
        XCTAssertEqual(AudioScan.subfolderOnly(names, machine: "Elsewhere"), [])

        let files = AudioScan.subfolderOnly(names, machine: "Gallery 2").map { InventoryFile(name: $0, duration: 0) }
        let works = PlaylistMerge.merge([Work(name: "W")], with: [Inventory(machine: "Gallery 2", displays: 1, folders: [:], audio: ["W": files])])
        XCTAssertEqual(works[0].routes(on: "Gallery 2"), [AudioRoute(file: "W/audio/Gallery 2/a_3.wav", output: 3)])
    }

    func testAPlayersPansAreRecorded() throws {
        let show = Show(machines: [Machine(name: "P", displays: 1)])
        XCTAssertEqual(SharedShow.setPans(show, machine: "P", pans: [3: 0.5]).machines[0].pans, [3: 0.5])
        XCTAssertEqual(SharedShow.setPans(show, machine: "Q", pans: [3: 0.5]), show)
        var reader = LinkFraming.Reader()
        let m = LinkMessage.setPans(machine: "P", pans: [3: 0.5])
        XCTAssertEqual(try reader.feed(LinkFraming.frame(m)), [m])
    }

    // MARK: Device

    private let speakers = AudioOutputs.Device(uid: "s", name: "Speakers", outputs: 2)
    private let behringer = AudioOutputs.Device(uid: "b", name: "Behringer", outputs: 10)
    private let bridge = AudioOutputs.Device(uid: "v", name: "Bridge", outputs: 16, isVirtual: true)

    func testPickUsesTheDefaultOutputIfItIsBigEnough() {
        XCTAssertEqual(AudioOutputs.pick(devices: [speakers, behringer], chosen: nil, defaultUID: "b", needed: 8), behringer)
        XCTAssertEqual(AudioOutputs.pick(devices: [speakers, behringer], chosen: nil, defaultUID: "s", needed: 2), speakers)
    }

    /// The likely install: the interface is plugged in, the default is still the speakers.
    func testPickFindsTheOnlyRealInterfaceBigEnoughAndIgnoresVirtualOnes() {
        XCTAssertEqual(AudioOutputs.pick(devices: [speakers, behringer, bridge], chosen: nil, defaultUID: "s", needed: 8), behringer)
        XCTAssertNil(AudioOutputs.pick(devices: [speakers, bridge], chosen: nil, defaultUID: "s", needed: 8))
    }

    func testPickDoesNotGuessBetweenInterfaces() {
        let other = AudioOutputs.Device(uid: "o", name: "Other", outputs: 16)
        XCTAssertNil(AudioOutputs.pick(devices: [speakers, behringer, other], chosen: nil, defaultUID: "s", needed: 8))
    }

    func testAChosenDeviceWinsIfConnectedAndIsIgnoredIfNot() {
        XCTAssertEqual(AudioOutputs.pick(devices: [speakers, behringer], chosen: "s", defaultUID: "b", needed: 8), speakers)
        XCTAssertEqual(AudioOutputs.pick(devices: [speakers, behringer], chosen: "gone", defaultUID: "b", needed: 8), behringer)
    }
}
