//
//  ListenReporterTest.swift
//  AmperfyKitTests
//
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

@testable import AmperfyKit
import CoreData
import XCTest

// MARK: - ListenReporterTest

@MainActor
class ListenReporterTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var storage: PersistentStorage!
  var reporter: ListenReporter!
  var playing: Song?
  var clock = Date(timeIntervalSince1970: 1_000_000)
  var songA: Song!
  var songB: Song!
  private var settingsBefore: UserSettings!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    storage = PersistentStorage(
      coreDataManager: MOCK_CoreDataManager(persistentContainer: cdHelper.persistentContainer)
    )
    settingsBefore = storage.settings.user
    storage.settings.user.isListenReportEnabled = true
    storage.settings.user.isOfflineMode = true // queue only: the tests must not reach a network
    SmartShuffle.skipCounts = [:]
    songA = library.getSong(for: account, id: cdHelper.seeder.songs[0].id)
    songB = library.getSong(for: account, id: cdHelper.seeder.songs[1].id)
    songA.playableManagedObject.combinedDuration = 200
    songB.playableManagedObject.combinedDuration = 200
    reporter = ListenReporter(
      currentSong: { self.playing },
      account: account,
      storage: storage,
      now: { self.clock }
    )
    try? FileManager.default.removeItem(at: reporter.queueFile)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: reporter.queueFile)
    storage.settings.user = settingsBefore
    SmartShuffle.skipCounts = [:]
  }

  private func start(_ song: Song) {
    playing = song
    reporter.didStartPlayingFromBeginning()
    reporter.didStartPlaying()
  }

  func testSkipThenFullListenThenStop() {
    start(songA)
    clock += 12
    start(songB) // skipped A after 12 s
    clock += 100
    reporter.didPause()
    clock += 500 // paused: does not count
    reporter.didStartPlaying()
    clock += 95
    reporter.didStopPlaying() // B played 195 of 200 s

    let queue = reporter.loadQueue()
    XCTAssertEqual(queue.count, 2)
    XCTAssertEqual(queue[0].id, songA.id)
    XCTAssertEqual(queue[0].seconds, 12)
    XCTAssertEqual(queue[0].ended, "next")
    XCTAssertEqual(queue[0].started, 1_000_000)
    XCTAssertEqual(queue[0].finished, 1_000_012)
    XCTAssertTrue(queue[0].isSkip)
    XCTAssertEqual(queue[1].id, songB.id)
    XCTAssertEqual(queue[1].seconds, 195)
    XCTAssertEqual(queue[1].ended, "stopped")
    XCTAssertEqual(queue[1].finished, 1_000_707)
    XCTAssertFalse(queue[1].isSkip)
    XCTAssertEqual(SmartShuffle.skipCounts, [songA.id: 1])
  }

  func testReplayIsAnnouncedTwiceButCountedOnce() {
    start(songA)
    clock += 30
    reporter.didStartPlayingFromBeginning() // the player's first announcement of a replay
    start(songA) // the second one, when the song is ready
    clock += 190
    start(songB)

    let queue = reporter.loadQueue()
    XCTAssertEqual(queue.map { $0.seconds }, [30, 190])
    XCTAssertEqual(queue.map { $0.id }, [songA.id, songA.id])
    XCTAssertEqual(SmartShuffle.skipCounts, [:]) // the full listen cleared the skip
  }

  func testNothingIsQueuedWhenReportsAreOffButSkipsStillCount() {
    storage.settings.user.isListenReportEnabled = false
    start(songA)
    clock += 5
    start(songB)
    XCTAssertEqual(reporter.loadQueue(), [])
    XCTAssertEqual(SmartShuffle.skipCounts, [songA.id: 1])
  }

  func testSmartShuffleWeight() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    XCTAssertEqual(SmartShuffle.weight(lastPlayed: nil, skips: 0, now: now), 1)
    XCTAssertEqual(SmartShuffle.weight(lastPlayed: now, skips: 0, now: now), 0.1)
    XCTAssertEqual(
      SmartShuffle.weight(lastPlayed: now.addingTimeInterval(-24 * 3600), skips: 0, now: now),
      0.5
    )
    XCTAssertEqual(
      SmartShuffle.weight(lastPlayed: now.addingTimeInterval(-90 * 3600), skips: 2, now: now),
      0.25
    )
    XCTAssertEqual(SmartShuffle.weight(lastPlayed: nil, skips: 99, now: now), 0.0625)
  }

  func testSmartShuffleOrderPushesLowWeightsBack() {
    // 20 normal items and 20 of weight 0.01: fully separated the low ones' positions sum to
    // 590, an even shuffle gives 390 on average
    for _ in 0 ..< 20 {
      let order = SmartShuffle.order(Array(0 ..< 40)) { $0 < 20 ? 1 : 0.01 }
      XCTAssertEqual(order.sorted(), Array(0 ..< 40))
      let lowPositions = order.enumerated().filter { $0.element >= 20 }.map { $0.offset }
      XCTAssertGreaterThan(lowPositions.reduce(0, +), 520)
    }
    // equal weights still mix
    XCTAssertNotEqual(
      SmartShuffle.order(Array(0 ..< 40)) { _ in 1 },
      SmartShuffle.order(Array(0 ..< 40)) { _ in 1 }
    )
  }

  func testPlaylistShuffleWithWeightsKeepsEverySong() {
    let playlist = library.createPlaylist(account: account)
    let songs = (0 ..< 8).compactMap {
      library.getSong(for: account, id: cdHelper.seeder.songs[$0].id)
    }
    playlist.append(playables: songs)
    XCTAssertGreaterThan(songs.count, 3)
    guard let last = songs.last else { return }
    playlist.shuffle(weight: { $0 == last ? 1 : 0 })
    XCTAssertEqual(playlist.playables.count, songs.count)
    XCTAssertEqual(Set(playlist.playables.map { $0.id }), Set(songs.map { $0.id }))
    XCTAssertEqual(playlist.playables.first?.id, last.id)
  }
}

// MARK: - Crossfade

extension MusicPlayerTest {
  private func waitSeconds(_ seconds: TimeInterval) {
    let nothing = expectation(description: "only waits")
    nothing.isInverted = true
    wait(for: [nothing], timeout: seconds)
  }

  func testCrossfadeVolumes() {
    let begin = BackendAudioPlayer.crossfadeVolumes(progress: 0)
    XCTAssertEqual(begin.fadeOut, 1, accuracy: 0.001)
    XCTAssertEqual(begin.fadeIn, 0, accuracy: 0.001)
    let middle = BackendAudioPlayer.crossfadeVolumes(progress: 0.5)
    XCTAssertEqual(middle.fadeOut, middle.fadeIn, accuracy: 0.001)
    // equal power: the summed energy stays constant
    XCTAssertEqual(middle.fadeOut * middle.fadeOut + middle.fadeIn * middle.fadeIn, 1, accuracy: 0.001)
    let end = BackendAudioPlayer.crossfadeVolumes(progress: 7)
    XCTAssertEqual(end.fadeOut, 0, accuracy: 0.001)
    XCTAssertEqual(end.fadeIn, 1, accuracy: 0.001)
  }

  /// In the last seconds the next song starts on a second player while the first one fades out
  func testCrossfade_NextSongStartsOnSecondPlayer_FirstOneIsStoppedAfterwards() {
    backendPlayer.isCrossfadeEnabledCB = { true }
    let first = mockAudioStreamingPlayer!
    songCached.remoteDuration = 60
    testPlayer.appendContextQueue(playables: [songCached, songToDownload])
    testPlayer.play()
    first.mockElapsedTime = 58.5 // 1.5 s left
    let second = MOCK_AudioStreamingPlayer()
    mockAudioStreamingPlayer = second // what the backend gets when it asks for a new player

    waitSeconds(1.6) // the check runs once per second
    XCTAssertEqual(testPlayer.currentlyPlaying, songToDownload)
    XCTAssertTrue(first.queuedUrls.isEmpty) // not queued behind the first song
    XCTAssertFalse(first.isStopped) // still fading out
    XCTAssertTrue(second.isPlaying)

    waitSeconds(2.0) // the fade lasts as long as the first song had left
    XCTAssertTrue(first.isStopped)
    XCTAssertTrue(second.isPlaying)
    XCTAssertEqual(second.volume, 1, accuracy: 0.01)
    XCTAssertTrue(testPlayer.isPlaying)
  }

  /// Pausing during the overlap ends it: only the new song is left, paused
  func testCrossfade_PauseCutsTheOverlap() {
    backendPlayer.isCrossfadeEnabledCB = { true }
    let first = mockAudioStreamingPlayer!
    songCached.remoteDuration = 60
    testPlayer.appendContextQueue(playables: [songCached, songToDownload])
    testPlayer.play()
    first.mockElapsedTime = 55 // 5 s left
    let second = MOCK_AudioStreamingPlayer()
    mockAudioStreamingPlayer = second

    waitSeconds(1.6)
    XCTAssertFalse(first.isStopped)
    testPlayer.pause()
    XCTAssertTrue(first.isStopped)
    XCTAssertFalse(second.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, songToDownload)
  }

  /// Runs the main run loop until the condition holds
  private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
  }

  private static func sineWav(seconds: Int, frequency: Double) -> Data {
    let rate = 22050
    let sampleCount = rate * seconds
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + sampleCount * 2))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16)) // PCM header size
    append(UInt16(1)) // PCM
    append(UInt16(1)) // mono
    append(UInt32(rate))
    append(UInt32(rate * 2))
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(sampleCount * 2))
    for index in 0 ..< sampleCount {
      append(Int16(8000 * sin(2 * Double.pi * frequency * Double(index) / Double(rate))))
    }
    return data
  }

  /// The same hand-over with the real audio players and two real files: both engines run at
  /// once and the second song really advances. Skipped where no audio can be played.
  func testCrossfade_RealPlayers_SecondSongPlaysOn() throws {
    let backend = BackendAudioPlayer(
      createAudioStreamingPlayerCB: { AudioStreamingPlayer() },
      audioSessionHandler: AudioSessionHandler(),
      eventLogger: eventLogger,
      getBackendApiCB: { accountInfo in self.backendApi },
      networkMonitor: networkMonitor,
      getPlayableDownloaderCB: { accountInfo in self.songDownloader },
      cacheProxy: library,
      userStatistics: userStatistics
    )
    backend.isCrossfadeEnabledCB = { true }
    let queueHandler = PlayQueueHandler(playerData: playerData)
    let musicPlayer = AudioPlayer(
      coreData: playerData,
      queueHandler: queueHandler,
      backendAudioPlayer: backend,
      settings: storage.settings,
      userStatistics: userStatistics
    )
    let player: PlayerFacade = PlayerFacadeImpl(
      playerStatus: playerData,
      queueHandler: queueHandler,
      musicPlayer: musicPlayer,
      library: library,
      backendAudioPlayer: backend,
      userStatistics: userStatistics
    )
    let songs: [(Song, String, Double)] = [
      (songCached, "crossfadeA.wav", 440), (songToDownload, "crossfadeB.wav", 660),
    ]
    for (song, name, frequency) in songs {
      let relFilePath = URL(string: name)!
      let absFilePath = CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: relFilePath)!
      try CacheFileManager.shared.writeDataExcludedFromBackup(
        data: Self.sineWav(seconds: 24, frequency: frequency),
        to: absFilePath, accountInfo: account.info
      )
      song.relFilePath = relFilePath
      song.remoteDuration = 24
    }
    player.appendContextQueue(playables: [songCached, songToDownload])
    player.play()
    guard waitUntil(8, { player.isPlaying && player.elapsedTime > 0.3 }) else {
      player.stop()
      throw XCTSkip("no audio can be played here (elapsed \(player.elapsedTime))")
    }
    print("CROSSFADE-REAL first song runs, elapsed \(player.elapsedTime) of \(player.duration)")

    player.seek(toSecond: 19.5) // 4.5 s left: inside the crossfade window
    XCTAssertTrue(waitUntil(6, { player.currentlyPlaying == self.songToDownload }))
    XCTAssertTrue(waitUntil(6, { player.isPlaying && player.elapsedTime > 0.5 }))
    XCTAssertLessThan(player.elapsedTime, 10) // the second song's own position, not the first one's
    let duringFade = player.elapsedTime
    print("CROSSFADE-REAL second song runs during the fade, elapsed \(duringFade)")

    XCTAssertTrue(waitUntil(8, { player.elapsedTime > duringFade + 5 })) // past the fade, still advancing
    XCTAssertTrue(player.isPlaying)
    XCTAssertEqual(player.currentlyPlaying, songToDownload)
    print("CROSSFADE-REAL second song runs after the fade, elapsed \(player.elapsedTime)")
    player.stop()
  }

  /// Switched off, the next song is queued behind the current one on the same player
  func testCrossfadeOff_NextSongIsQueuedGapless() {
    backendPlayer.isCrossfadeEnabledCB = { false }
    let first = mockAudioStreamingPlayer!
    songCached.remoteDuration = 60
    testPlayer.appendContextQueue(playables: [songCached, songToDownload])
    testPlayer.play()
    first.mockElapsedTime = 58.5

    waitSeconds(2.0)
    XCTAssertEqual(first.queuedUrls.count, 1)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
  }
}
