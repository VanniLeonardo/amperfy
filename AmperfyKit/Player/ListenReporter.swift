//
//  ListenReporter.swift
//  AmperfyKit
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

import Foundation
import os.log

// MARK: - SmartShuffle

/// Smart Shuffle (Settings > Player): a shuffle that moves songs played in the last two days
/// and songs that keep being skipped towards the back instead of treating every song alike.
enum SmartShuffle {
  private static let skipCountsKey = "smartShuffleSkipCounts"

  /// Skips in a row per song id; hearing a song to the end clears its entry
  static var skipCounts: [String: Int] {
    get { UserDefaults.standard.dictionary(forKey: skipCountsKey) as? [String: Int] ?? [:] }
    set { UserDefaults.standard.set(newValue, forKey: skipCountsKey) }
  }

  /// How likely a song is to come early: 1 is normal, 0.1 is the lowest for a song played
  /// just now (back to 1 after 48 hours), halved for every skip in a row (4 at most).
  static func weight(lastPlayed: Date?, skips: Int, now: Date) -> Double {
    let hours = lastPlayed.map { now.timeIntervalSince($0) / 3600 } ?? 48
    let recency = min(1, max(0.1, hours / 48))
    return recency * pow(0.5, Double(min(max(skips, 0), 4)))
  }

  static func weights(now: Date = Date()) -> (AbstractPlayable) -> Double {
    let skips = skipCounts
    return { weight(lastPlayed: $0.lastTimePlayed, skips: skips[$0.id] ?? 0, now: now) }
  }

  /// Weighted random order: an item of weight 1 is ten times as likely to come first as an
  /// item of weight 0.1 (sort by random^(1/weight), highest first)
  static func order<T>(_ items: [T], weight: (T) -> Double) -> [T] {
    items
      .map { ($0, pow(Double.random(in: 0 ..< 1), 1 / max(weight($0), 0.000001))) }
      .sorted { $0.1 > $1.1 }
      .map { $0.0 }
  }
}

// MARK: - ListenReporter

/// Follows what is played and for how long.
/// - Listening Reports (Settings > Player, opt-in): tells a small receiver next to the music
///   server (`<server url>/add/listens`) how long each song really played. Subsonic scrobbles
///   carry no duration and are only sent after half a song, so the server cannot see skips.
///   Listens wait in a file until the receiver has confirmed them, so offline plays arrive later.
/// - Counts skips per song for Smart Shuffle.
@MainActor
class ListenReporter {
  struct Listen: Codable, Equatable {
    let id: String
    let artist: String
    let title: String
    let duration: Int
    let started: Int // epoch seconds
    var finished = 0 // epoch seconds
    var seconds = 0 // time it really played, pauses excluded
    var ended = "" // "next": another song followed, "stopped": playback stopped

    /// The same rule as the scrobble threshold: left before half the song or 4 minutes
    var isSkip: Bool {
      ended == "next" && duration > 0 && Double(seconds) < min(Double(duration) / 2, 240)
    }
  }

  private struct Upload: Codable {
    let user: String
    let listens: [Listen]
  }

  private struct Reject: Codable {
    let user: String
    let id: String
  }

  private struct RejectAnswer: Codable {
    let removed: Bool
  }

  private static let maxQueued = 5000 // receiver never reachable: keep the newest

  private let log = OSLog(subsystem: "Amperfy", category: "ListenReporter")
  private let currentSong: @MainActor () -> Song?
  private let account: Account
  private let storage: PersistentStorage
  private let now: () -> Date
  let queueFile: URL

  private var current: Listen?
  private var playedTime: TimeInterval = 0
  private var resumedAt: Date?
  private var isUploading = false

  init(
    currentSong: @escaping @MainActor () -> Song?,
    account: Account,
    storage: PersistentStorage,
    now: @escaping () -> Date = { Date() }
  ) {
    self.currentSong = currentSong
    self.account = account
    self.storage = storage
    self.now = now
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.queueFile = dir
      .appendingPathComponent("listens-\(account.serverHash)-\(account.userHash).json")
  }

  private func pauseClock() {
    if let resumedAt {
      playedTime += now().timeIntervalSince(resumedAt)
    }
    resumedAt = nil
  }

  // shortcut: a song that is paused when the app is killed is not reported, persist `current` if that matters
  private func finishCurrent(ended: String) {
    pauseClock()
    guard var listen = current else { return }
    current = nil
    listen.seconds = Int(playedTime.rounded())
    listen.finished = Int(now().timeIntervalSince1970)
    listen.ended = ended
    playedTime = 0

    if listen.isSkip {
      SmartShuffle.skipCounts[listen.id, default: 0] += 1
    } else if Double(listen.seconds) >= 0.9 * Double(listen.duration) {
      SmartShuffle.skipCounts[listen.id] = nil
    }
    guard storage.settings.user.isListenReportEnabled else { return }
    saveQueue(Array((loadQueue() + [listen]).suffix(Self.maxQueued)))
    upload()
  }

  func loadQueue() -> [Listen] {
    guard let data = try? Data(contentsOf: queueFile) else { return [] }
    return (try? JSONDecoder().decode([Listen].self, from: data)) ?? []
  }

  private func saveQueue(_ queue: [Listen]) {
    try? JSONEncoder().encode(queue).write(to: queueFile, options: .atomic)
  }

  /// POSTs JSON to `<server url>/add/<endpoint>`; nil unless the receiver answered 200
  private func post(_ endpoint: String, body: some Encodable) async -> Data? {
    guard let url = URL(string: account.serverUrl)?.appendingPathComponent("add/\(endpoint)"),
          let json = try? JSONEncoder().encode(body) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = json
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return data
  }

  /// Sends everything queued. Listens stay in the file until the receiver answers 200.
  func upload() {
    guard storage.settings.user.isListenReportEnabled, storage.settings.user.isOnlineMode,
          !isUploading else { return }
    let queue = loadQueue()
    guard let lastSent = queue.last else { return }
    isUploading = true
    Task { @MainActor in
      defer { self.isUploading = false }
      guard await self.post("listens", body: Upload(user: self.account.userName, listens: queue))
        != nil
      else {
        os_log("Upload failed, %d listens queued", log: self.log, type: .info, queue.count)
        return
      }
      // a listen that finished during the upload stays queued
      self.saveQueue(self.loadQueue().filter { $0.finished > lastSent.finished })
    }
  }

  /// "Not for me": the receiver notes the dislike and deletes the song if it is a Discover
  /// pick. Returns whether it was deleted, nil if the receiver could not be reached.
  func reject(song: Song) async -> Bool? {
    guard let data = await post("reject", body: Reject(user: account.userName, id: song.id))
    else { return nil }
    return (try? JSONDecoder().decode(RejectAnswer.self, from: data))?.removed
  }
}

// MARK: MusicPlayable

extension ListenReporter: MusicPlayable {
  func didStartPlayingFromBeginning() {
    let song = currentSong()
    // the player announces a replay twice: keep the listen that has just begun
    if let current, current.id == song?.id, playedTime == 0, resumedAt == nil { return }
    finishCurrent(ended: "next")
    guard let song, song.account == account else { return }
    current = Listen(
      id: song.id,
      artist: song.creatorName,
      title: song.title,
      duration: song.duration,
      started: Int(now().timeIntervalSince1970)
    )
  }

  func didStartPlaying() {
    if current != nil, resumedAt == nil {
      resumedAt = now()
    }
  }

  func didPause() {
    pauseClock()
  }

  func didStopPlaying() {
    finishCurrent(ended: "stopped")
  }

  func didElapsedTimeChange() {}
  func didPlaylistChange() {}
  func didArtworkChange() {}
  func didShuffleChange() {}
  func didRepeatChange() {}
  func didPlaybackRateChange() {}
}
