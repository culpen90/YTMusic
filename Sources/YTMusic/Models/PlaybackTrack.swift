import Foundation

struct PlaybackSegment: Hashable, Sendable {
  let startTime: Double
  let endTime: Double
}

struct PlaybackTimeline: Hashable, Sendable {
  let sourceDuration: Double
  let excludedSegments: [PlaybackSegment]

  init?(sourceDuration: Double, excludedSegments: [PlaybackSegment]) {
    guard sourceDuration.isFinite, sourceDuration > 0, sourceDuration <= 86_400 else {
      return nil
    }

    let leadingTolerance = 0.1
    let trailingTolerance = 0.1
    let candidates =
      excludedSegments
      .compactMap { segment -> PlaybackSegment? in
        guard segment.startTime.isFinite, segment.endTime.isFinite,
          segment.startTime >= 0,
          segment.startTime < sourceDuration,
          segment.endTime > segment.startTime,
          segment.endTime <= sourceDuration + trailingTolerance
        else {
          return nil
        }
        return PlaybackSegment(
          startTime: segment.startTime <= leadingTolerance ? 0 : segment.startTime,
          endTime: segment.endTime >= sourceDuration - trailingTolerance
            ? sourceDuration : segment.endTime
        )
      }
      .sorted { lhs, rhs in
        lhs.startTime == rhs.startTime
          ? lhs.endTime < rhs.endTime : lhs.startTime < rhs.startTime
      }
      .prefix(128)

    var merged: [PlaybackSegment] = []
    for segment in candidates {
      if let previous = merged.last, segment.startTime <= previous.endTime + 0.01 {
        merged[merged.count - 1] = PlaybackSegment(
          startTime: previous.startTime,
          endTime: max(previous.endTime, segment.endTime)
        )
      } else {
        merged.append(segment)
      }
    }

    let excludedDuration = merged.reduce(0) { partial, segment in
      partial + segment.endTime - segment.startTime
    }
    if sourceDuration - excludedDuration <= 0.05 {
      merged.removeAll()
    }

    self.sourceDuration = sourceDuration
    self.excludedSegments = merged
  }

  var duration: Double {
    sourceDuration
      - excludedSegments.reduce(0) { partial, segment in
        partial + segment.endTime - segment.startTime
      }
  }

  var sourceStartTime: Double {
    guard let first = excludedSegments.first, first.startTime == 0 else { return 0 }
    return first.endTime
  }

  var sourceEndTime: Double {
    guard let last = excludedSegments.last, last.endTime == sourceDuration else {
      return sourceDuration
    }
    return last.startTime
  }

  var internalBoundaryTimes: [Double] {
    excludedSegments.compactMap { segment in
      guard segment.startTime > sourceStartTime, segment.startTime < sourceEndTime else {
        return nil
      }
      return segment.startTime
    }
  }

  func playbackTime(forSourceTime sourceTime: Double) -> Double {
    let clampedTime = min(max(sourceTime, 0), sourceEndTime)
    var skippedDuration = 0.0
    for segment in excludedSegments {
      if clampedTime >= segment.endTime {
        skippedDuration += segment.endTime - segment.startTime
      } else if clampedTime > segment.startTime {
        skippedDuration += clampedTime - segment.startTime
        break
      } else {
        break
      }
    }
    return min(max(clampedTime - skippedDuration, 0), duration)
  }

  func sourceTime(forPlaybackTime playbackTime: Double) -> Double {
    let clampedTime = min(max(playbackTime, 0), duration)
    if clampedTime == duration { return sourceEndTime }

    var sourceTime = clampedTime
    for segment in excludedSegments {
      if sourceTime >= segment.startTime {
        sourceTime += segment.endTime - segment.startTime
      } else {
        break
      }
    }
    return min(max(sourceTime, sourceStartTime), sourceEndTime)
  }

  func skipTarget(forSourceTime sourceTime: Double) -> Double? {
    excludedSegments.first { segment in
      sourceTime >= segment.startTime - 0.01 && sourceTime < segment.endTime
    }?.endTime
  }
}

struct PlaybackStream: Hashable, Sendable {
  let audioURL: URL
  let userAgent: String?
  let timeline: PlaybackTimeline?

  init(audioURL: URL, userAgent: String?, timeline: PlaybackTimeline? = nil) {
    self.audioURL = audioURL
    self.userAgent = userAgent
    self.timeline = timeline
  }
}

struct PlaybackTrack: Identifiable, Hashable {
  enum Source: Hashable {
    case local(Track)
    case stream(PlaybackStream)
  }

  let metadata: SearchResult
  let source: Source

  init(local track: Track) {
    metadata = track.searchResult
    source = .local(track)
  }

  init(stream metadata: SearchResult, resolvedStream: PlaybackStream) {
    self.metadata = metadata
    source = .stream(resolvedStream)
  }

  var id: String { metadata.id }
  var title: String { metadata.title }
  var artist: String { metadata.artist }
  var duration: Double? { metadata.duration }
  var thumbnailURL: URL? { metadata.thumbnailURL }

  var audioURL: URL {
    switch source {
    case .local(let track): track.audioURL
    case .stream(let stream): stream.audioURL
    }
  }

  var localTrack: Track? {
    guard case .local(let track) = source else { return nil }
    return track
  }

  var localFilePath: String? { localTrack?.localFilePath }
  var artworkURL: URL? { localTrack?.artworkURL }
  var resolvedStream: PlaybackStream? {
    guard case .stream(let stream) = source else { return nil }
    return stream
  }
  var isStreaming: Bool {
    if case .stream = source { return true }
    return false
  }
}
