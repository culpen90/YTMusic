import Foundation

struct PlaybackStream: Hashable, Sendable {
  let audioURL: URL
  let userAgent: String?
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
