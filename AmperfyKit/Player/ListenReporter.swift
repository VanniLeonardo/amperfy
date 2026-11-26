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

// MARK: - ListenReporter

/// Tells a small receiver next to the music server (`<server url>/add/listens`) how long each
/// song really played. Subsonic scrobbles carry no duration and are only sent after half a
/// song, so the server cannot see skips. Opt-in: Settings > Player > Listening Reports.
/// Listens wait in a file until the receiver has confirmed them, so offline plays arrive later.
@MainActor
class ListenReporter {
  struct Listen: Codable {
    let id: String
    let artist: String
    let title: String
    let duration: Int
    let started: Int // epoch seconds
    var finished = 0 // epoch seconds
    var seconds = 0 // time it really played, pauses excluded
    var ended = "" // "next": another song followed, "stopped": playback stopped
  }

  private struct Upload: Codable {
    let user: String
    let listens: [Listen]
  }

  private static let maxQueued = 5000 // receiver never reachable: keep the newest

  private let log = OSLog(subsystem: "Amperfy", category: "ListenReporter")
  private let player: PlayerFacade
  private let account: Account
  private let storage: PersistentStorage
  private let queueFile: URL

  private var current: Listen?
  private var playedTime: TimeInterval = 0
  private var resumedAt: Date?
  private var isUploading = false

  init(player: PlayerFacade, account: Account, storage: PersistentStorage) {
    self.player = player
    self.account = account
    self.storage = storage
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.queueFile = dir
      .appendingPathComponent("listens-\(account.serverHash)-\(account.userHash).json")
  }

  private func pauseClock() {
    if let resumedAt {
      playedTime += Date().timeIntervalSince(resumedAt)
    }
    resumedAt = nil
  }

  // shortcut: a song that is paused when the app is killed is not reported, persist `current` if that matters
  private func finishCurrent(ended: String) {
    pauseClock()
    guard var listen = current else { return }
    current = nil
    listen.seconds = Int(playedTime.rounded())
    listen.finished = Int(Date().timeIntervalSince1970)
    listen.ended = ended
    playedTime = 0
    saveQueue(Array((loadQueue() + [listen]).suffix(Self.maxQueued)))
    upload()
  }

  private func loadQueue() -> [Listen] {
    guard let data = try? Data(contentsOf: queueFile) else { return [] }
    return (try? JSONDecoder().decode([Listen].self, from: data)) ?? []
  }

  private func saveQueue(_ queue: [Listen]) {
    try? JSONEncoder().encode(queue).write(to: queueFile, options: .atomic)
  }

  /// Sends everything queued. Listens stay in the file until the receiver answers 200.
  func upload() {
    guard storage.settings.user.isListenReportEnabled, storage.settings.user.isOnlineMode,
          !isUploading else { return }
    let queue = loadQueue()
    guard let lastSent = queue.last,
          let url = URL(string: account.serverUrl)?.appendingPathComponent("add/listens"),
          let body = try? JSONEncoder().encode(Upload(user: account.userName, listens: queue))
    else { return }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    isUploading = true
    Task { @MainActor in
      defer { self.isUploading = false }
      guard let (_, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
      else {
        os_log("Upload failed, %d listens queued", log: self.log, type: .info, queue.count)
        return
      }
      // a listen that finished during the upload stays queued
      self.saveQueue(self.loadQueue().filter { $0.finished > lastSent.finished })
    }
  }
}

// MARK: MusicPlayable

extension ListenReporter: MusicPlayable {
  func didStartPlayingFromBeginning() {
    let song = player.currentlyPlaying?.asSong
    // the player announces a replay twice: keep the listen that has just begun
    if let current, current.id == song?.id, playedTime == 0, resumedAt == nil { return }
    finishCurrent(ended: "next")
    guard storage.settings.user.isListenReportEnabled, let song, song.account == account
    else { return }
    current = Listen(
      id: song.id,
      artist: song.creatorName,
      title: song.title,
      duration: song.duration,
      started: Int(Date().timeIntervalSince1970)
    )
  }

  func didStartPlaying() {
    if current != nil, resumedAt == nil {
      resumedAt = Date()
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
