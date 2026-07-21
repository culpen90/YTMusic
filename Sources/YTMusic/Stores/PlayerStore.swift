import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlayerStore {
  private(set) var currentTrack: Track?
  private(set) var isPlaying = false
  private(set) var currentTime: Double = 0
  private(set) var duration: Double = 0
  var volume: Double = 0.85 {
    didSet { player.volume = Float(volume) }
  }
  var errorMessage: String?

  var onTemporaryTrackFinished: ((Track) -> Void)?
  var onTrackEnded: ((Track) -> Void)?
  var onTrackStarted: ((Track) -> Void)?

  private let player = AVPlayer()
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var failureObserver: NSObjectProtocol?

  init() {
    player.volume = Float(volume)
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      let seconds = time.seconds
      Task { @MainActor in
        guard let self else { return }
        if seconds.isFinite { self.currentTime = max(0, seconds) }
        if let item = self.player.currentItem {
          let itemDuration = item.duration.seconds
          if itemDuration.isFinite && itemDuration > 0 { self.duration = itemDuration }
        }
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let itemIdentifier = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
      Task { @MainActor in
        guard let self, let currentItem = self.player.currentItem,
          itemIdentifier == ObjectIdentifier(currentItem)
        else {
          return
        }
        self.finishCurrentTrack(naturalEnd: true)
      }
    }
    failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let itemIdentifier = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
      let failureDescription =
        (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
        .localizedDescription
      Task { @MainActor in
        guard let self, let currentItem = self.player.currentItem,
          itemIdentifier == ObjectIdentifier(currentItem)
        else {
          return
        }
        self.errorMessage = failureDescription ?? "The audio file could not be played."
        self.finishCurrentTrack(naturalEnd: true)
      }
    }
  }

  func play(_ track: Track) {
    if currentTrack?.id != track.id || currentTrack?.localFilePath != track.localFilePath {
      finishCurrentTrack(naturalEnd: false)
    }
    guard FileManager.default.fileExists(atPath: track.audioURL.path) else {
      errorMessage = "The audio file is no longer available."
      return
    }
    currentTrack = track
    currentTime = 0
    duration = track.duration ?? 0
    errorMessage = nil
    player.replaceCurrentItem(with: AVPlayerItem(url: track.audioURL))
    player.play()
    isPlaying = true
    onTrackStarted?(track)
  }

  func togglePlayback() {
    guard currentTrack != nil else { return }
    if isPlaying {
      player.pause()
      isPlaying = false
    } else {
      player.play()
      isPlaying = true
    }
  }

  func seek(to seconds: Double) {
    guard seconds.isFinite else { return }
    player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    currentTime = max(0, seconds)
  }

  func restart() {
    guard currentTrack != nil else {
      isPlaying = false
      return
    }
    seek(to: 0)
    if !isPlaying {
      player.play()
      isPlaying = true
    }
  }

  func stopForReplacement() {
    finishCurrentTrack(naturalEnd: false)
  }

  func shutdown() {
    finishCurrentTrack(naturalEnd: false)
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    if let failureObserver {
      NotificationCenter.default.removeObserver(failureObserver)
      self.failureObserver = nil
    }
  }

  private func finishCurrentTrack(naturalEnd: Bool) {
    guard let oldTrack = currentTrack else { return }
    player.pause()
    player.replaceCurrentItem(with: nil)
    currentTrack = nil
    isPlaying = false
    currentTime = 0
    duration = 0
    if oldTrack.storage == .temporary {
      onTemporaryTrackFinished?(oldTrack)
    }
    if naturalEnd {
      onTrackEnded?(oldTrack)
    }
  }
}
