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
