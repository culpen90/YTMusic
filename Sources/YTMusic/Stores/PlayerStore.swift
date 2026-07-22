import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlayerStore {
  private(set) var currentTrack: PlaybackTrack?
  private(set) var isPlaying = false
  private(set) var isBuffering = false
  private(set) var currentTime: Double = 0
  private(set) var duration: Double = 0
  var volume: Double = 0.85 {
    didSet { player.volume = Float(volume) }
  }
  var errorMessage: String?

  var onTemporaryTrackFinished: ((Track) -> Void)?
  var onTrackEnded: ((PlaybackTrack) -> Void)?
  var onTrackStarted: ((Track) -> Void)?
  var onPlaybackStarted: ((PlaybackTrack) -> Void)?
  var onTrackFailed: ((PlaybackTrack) -> Void)?

  private let player = AVPlayer()
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var failureObserver: NSObjectProtocol?
  private var itemStatusObservation: NSKeyValueObservation?
  private var timeControlStatusObservation: NSKeyValueObservation?

  init() {
    player.automaticallyWaitsToMinimizeStalling = false
    player.volume = Float(volume)
    timeControlStatusObservation = player.observe(
      \.timeControlStatus,
      options: [.initial, .new]
    ) { [weak self] player, _ in
      Task { @MainActor in
        guard let self else { return }
        self.isPlaying = self.currentTrack != nil && player.timeControlStatus == .playing
        self.isBuffering =
          self.currentTrack != nil && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      }
    }
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
        let failedTrack = self.currentTrack
        self.errorMessage = failureDescription ?? "The audio file could not be played."
        self.finishCurrentTrack(naturalEnd: false)
        if let failedTrack { self.onTrackFailed?(failedTrack) }
      }
    }
  }

  func play(_ track: Track) {
    play(PlaybackTrack(local: track))
  }

  func play(stream metadata: SearchResult, resolvedStream: PlaybackStream) {
    play(PlaybackTrack(stream: metadata, resolvedStream: resolvedStream))
  }

  private func play(_ track: PlaybackTrack) {
    if currentTrack?.id != track.id || currentTrack?.audioURL != track.audioURL {
      finishCurrentTrack(naturalEnd: false)
    }
    if let localTrack = track.localTrack,
      !FileManager.default.fileExists(atPath: localTrack.audioURL.path)
    {
      errorMessage = "The audio file is no longer available."
      return
    }
    currentTrack = track
    currentTime = 0
    duration = track.duration ?? 0
    errorMessage = nil
    let item: AVPlayerItem
    if let stream = track.resolvedStream {
      let options: [String: Any]? = stream.userAgent.map {
        [AVURLAssetHTTPUserAgentKey: $0]
      }
      item = AVPlayerItem(asset: AVURLAsset(url: stream.audioURL, options: options))
    } else {
      item = AVPlayerItem(url: track.audioURL)
    }
    itemStatusObservation?.invalidate()
    itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard item.status == .failed else { return }
      let failureDescription = item.error?.localizedDescription
      Task { @MainActor in
        guard let self, self.player.currentItem === item else { return }
        let failedTrack = self.currentTrack
        self.errorMessage = failureDescription ?? "The audio stream could not be played."
        self.finishCurrentTrack(naturalEnd: false)
        if let failedTrack { self.onTrackFailed?(failedTrack) }
      }
    }
    player.replaceCurrentItem(with: item)
    player.play()
    if let localTrack = track.localTrack {
      onTrackStarted?(localTrack)
    }
    onPlaybackStarted?(track)
  }

  func togglePlayback() {
    guard currentTrack != nil else { return }
    if isPlaying || isBuffering {
      player.pause()
    } else {
      player.play()
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
    if !isPlaying && !isBuffering {
      player.play()
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
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    timeControlStatusObservation?.invalidate()
    timeControlStatusObservation = nil
  }

  private func finishCurrentTrack(naturalEnd: Bool) {
    guard let oldTrack = currentTrack else { return }
    player.pause()
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    player.replaceCurrentItem(with: nil)
    currentTrack = nil
    isPlaying = false
    isBuffering = false
    currentTime = 0
    duration = 0
    if let localTrack = oldTrack.localTrack, localTrack.storage == .temporary {
      onTemporaryTrackFinished?(localTrack)
    }
    if naturalEnd {
      onTrackEnded?(oldTrack)
    }
  }
}
