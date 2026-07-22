import Foundation

struct AutoplayHistory: Sendable {
  private(set) var playedIDs: Set<String> = []
  private var playedDurationsBySong: [SongIdentity: [Double?]] = [:]
  private var presentationAliases: Set<SongIdentity> = []

  mutating func record(_ item: SearchResult) {
    guard !item.id.isEmpty else { return }
    playedIDs.insert(item.id)
    guard let identity = SongIdentity(item) else { return }
    if identity.removedPresentationLabel {
      presentationAliases.insert(identity)
    }

    let duration = Self.normalizedDuration(item.duration)
    var durations = playedDurationsBySong[identity, default: []]
    if !durations.contains(where: { Self.durationsMatch($0, duration) }) {
      durations.append(duration)
      playedDurationsBySong[identity] = durations
    }
  }

  mutating func exclude(ids: Set<String>) {
    playedIDs.formUnion(ids)
  }

  func contains(_ item: SearchResult) -> Bool {
    if playedIDs.contains(item.id) { return true }
    guard let identity = SongIdentity(item),
      let durations = playedDurationsBySong[identity]
    else { return false }

    if identity.removedPresentationLabel || presentationAliases.contains(identity) {
      return true
    }

    let duration = Self.normalizedDuration(item.duration)
    return durations.contains { Self.durationsMatch($0, duration) }
  }

  private static func normalizedDuration(_ duration: Double?) -> Double? {
    guard let duration, duration.isFinite, duration > 0 else { return nil }
    return duration
  }

  private static func durationsMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
    guard let lhs, let rhs else { return true }
    let tolerance = max(5, min(lhs, rhs) * 0.05)
    return abs(lhs - rhs) <= tolerance
  }
}

private struct SongIdentity: Hashable, Sendable {
  let title: String
  let artist: String
  let removedPresentationLabel: Bool

  init?(_ item: SearchResult) {
    let normalizedTitle = Self.normalizedTitle(item.title)
    let title = normalizedTitle.value
    let artist = Self.normalizedArtist(item.artist)
    guard !title.isEmpty, !artist.isEmpty, artist != "unknown artist" else { return nil }

    self.title = title
    self.artist = artist
    removedPresentationLabel = normalizedTitle.removedPresentationLabel
  }

  static func == (lhs: SongIdentity, rhs: SongIdentity) -> Bool {
    lhs.title == rhs.title && lhs.artist == rhs.artist
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(title)
    hasher.combine(artist)
  }

  private static func normalizedTitle(_ value: String) -> (
    value: String, removedPresentationLabel: Bool
  ) {
    var title = normalized(value)
    let presentationLabels = [
      "official music video",
      "official lyric video",
      "official visualizer",
      "official video",
      "official audio",
      "music video",
      "lyric video",
      "visualizer",
      "lyrics",
    ]
    let delimiters = [" - ", " | "]
    var removedPresentationLabel = false

    var removedLabel = true
    while removedLabel {
      removedLabel = false
      for label in presentationLabels {
        let suffixes = [" (\(label))", " [\(label)]"] + delimiters.map { $0 + label }
        if let suffix = suffixes.first(where: { title.hasSuffix($0) }) {
          title.removeLast(suffix.count)
          title = title.trimmingCharacters(in: .whitespacesAndNewlines)
          removedLabel = true
          removedPresentationLabel = true
          break
        }
      }
    }
    return (title, removedPresentationLabel)
  }

  private static func normalizedArtist(_ value: String) -> String {
    var artist = normalized(value)
    if artist.hasSuffix(" - topic") {
      artist.removeLast(" - topic".count)
    } else if artist.hasSuffix("vevo"), artist.count > "vevo".count {
      artist.removeLast("vevo".count)
    }
    return artist.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func normalized(_ value: String) -> String {
    value
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }
}
