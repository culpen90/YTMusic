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
  var isPlaybackRequested: Bool { currentTrack != nil && wantsPlayback }
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
  private var boundaryTimeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var failureObserver: NSObjectProtocol?
  private var itemStatusObservation: NSKeyValueObservation?
  private var timeControlStatusObservation: NSKeyValueObservation?
  private var wantsPlayback = false
  private var pendingSkipTarget: Double?
  private var seekGeneration = UUID()

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
          self.currentTrack != nil && self.wantsPlayback
          && (player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            || self.pendingSkipTarget != nil)
      }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self, weak player] time in
      let seconds = time.seconds
      let itemIdentifier = player?.currentItem.map(ObjectIdentifier.init)
      Task { @MainActor in
        guard let self, let itemIdentifier, let currentItem = self.player.currentItem,
          ObjectIdentifier(currentItem) == itemIdentifier
        else {
          return
        }
        if let timeline = self.currentTrack?.resolvedStream?.timeline {
          if seconds.isFinite {
            self.currentTime = timeline.playbackTime(forSourceTime: seconds)
            if let currentItem = self.player.currentItem {
              _ = self.skipExcludedSegmentIfNeeded(
                at: seconds,
                timeline: timeline,
                itemIdentifier: ObjectIdentifier(currentItem)
              )
            }
          }
          self.duration = timeline.duration
          return
        }
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
    let timeline = track.resolvedStream?.timeline
    duration = timeline?.duration ?? track.duration ?? 0
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
    if let timeline {
      item.forwardPlaybackEndTime = Self.playerTime(timeline.sourceEndTime)
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
    removeBoundaryTimeObserver()
    player.replaceCurrentItem(with: item)
    wantsPlayback = true
    isBuffering = true
    if let timeline {
      installBoundaryTimeObserver(for: timeline, item: item)
      if timeline.sourceStartTime > 0 {
        seekPlayer(
          to: timeline.sourceStartTime,
          itemIdentifier: ObjectIdentifier(item),
          pendingSkipTarget: timeline.sourceStartTime
        )
      } else {
        player.play()
      }
    } else {
      player.play()
    }
    if let localTrack = track.localTrack {
      onTrackStarted?(localTrack)
    }
    onPlaybackStarted?(track)
  }

  func togglePlayback() {
    guard currentTrack != nil else { return }
    if wantsPlayback {
      wantsPlayback = false
      isPlaying = false
      isBuffering = false
      player.pause()
    } else {
      wantsPlayback = true
      isBuffering = true
      if pendingSkipTarget == nil {
        player.play()
      }
    }
  }

  func seek(to seconds: Double) {
    guard seconds.isFinite else { return }
    let playbackTime = max(0, min(seconds, duration > 0 ? duration : seconds))
    let sourceTime =
      currentTrack?.resolvedStream?.timeline?.sourceTime(forPlaybackTime: playbackTime)
      ?? playbackTime
    guard let item = player.currentItem else { return }
    seekPlayer(
      to: sourceTime,
      itemIdentifier: ObjectIdentifier(item)
    )
    currentTime = playbackTime
  }

  func restart() {
    guard currentTrack != nil else {
      isPlaying = false
      return
    }
    wantsPlayback = true
    seek(to: 0)
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
    removeBoundaryTimeObserver()
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
    wantsPlayback = false
    seekGeneration = UUID()
    pendingSkipTarget = nil
    player.currentItem?.cancelPendingSeeks()
    player.pause()
    removeBoundaryTimeObserver()
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

  private func installBoundaryTimeObserver(for timeline: PlaybackTimeline, item: AVPlayerItem) {
    let times = timeline.internalBoundaryTimes.map { NSValue(time: Self.playerTime($0)) }
    guard !times.isEmpty else { return }
    let itemIdentifier = ObjectIdentifier(item)
    boundaryTimeObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) {
      [weak self] in
      Task { @MainActor in
        guard let self, let currentItem = self.player.currentItem,
          ObjectIdentifier(currentItem) == itemIdentifier
        else {
          return
        }
        let sourceTime = self.player.currentTime().seconds
        guard sourceTime.isFinite else { return }
        _ = self.skipExcludedSegmentIfNeeded(
          at: sourceTime,
          timeline: timeline,
          itemIdentifier: itemIdentifier
        )
      }
    }
  }

  private func removeBoundaryTimeObserver() {
    if let boundaryTimeObserver {
      player.removeTimeObserver(boundaryTimeObserver)
      self.boundaryTimeObserver = nil
    }
  }

  @discardableResult
  private func skipExcludedSegmentIfNeeded(
    at sourceTime: Double,
    timeline: PlaybackTimeline,
    itemIdentifier: ObjectIdentifier
  ) -> Bool {
    guard pendingSkipTarget == nil,
      let target = timeline.skipTarget(forSourceTime: sourceTime),
      target < timeline.sourceEndTime
    else {
      return false
    }
    seekPlayer(
      to: target,
      itemIdentifier: itemIdentifier,
      pendingSkipTarget: target
    )
    return true
  }

  private func seekPlayer(
    to sourceTime: Double,
    itemIdentifier: ObjectIdentifier,
    pendingSkipTarget: Double? = nil
  ) {
    let generation = UUID()
    seekGeneration = generation
    player.currentItem?.cancelPendingSeeks()
    self.pendingSkipTarget = pendingSkipTarget
    if pendingSkipTarget != nil, wantsPlayback {
      isBuffering = true
    }
    player.seek(
      to: Self.playerTime(sourceTime),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] finished in
      Task { @MainActor in
        guard let self, self.seekGeneration == generation else { return }
        self.pendingSkipTarget = nil
        if !self.wantsPlayback {
          self.isBuffering = false
        }
        guard finished, let currentItem = self.player.currentItem,
          ObjectIdentifier(currentItem) == itemIdentifier
        else {
          return
        }
        if self.wantsPlayback {
          self.player.play()
        }
      }
    }
  }

  private static func playerTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
  }
}
