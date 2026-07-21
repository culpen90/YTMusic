import Foundation

struct SearchResult: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let title: String
  let artist: String
  let duration: Double?
  let webpageURLString: String
  let thumbnailURLString: String?

  var webpageURL: URL? { URL(string: webpageURLString) }
  var thumbnailURL: URL? { thumbnailURLString.flatMap(URL.init(string:)) }

  init(
    id: String,
    title: String,
    artist: String,
    duration: Double?,
    webpageURLString: String,
    thumbnailURLString: String?
  ) {
    self.id = id
    self.title = title
    self.artist = artist
    self.duration = duration
    self.webpageURLString = webpageURLString
    self.thumbnailURLString = thumbnailURLString
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, artist, uploader, channel, duration
    case webpageURL = "webpage_url"
    case url, thumbnail, thumbnails
    case extractorKey = "extractor_key"
  }

  private struct Thumbnail: Codable {
    let url: String?
    let width: Int?
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled"
    artist =
      [
        try? container.decodeIfPresent(String.self, forKey: .artist),
        try? container.decodeIfPresent(String.self, forKey: .uploader),
        try? container.decodeIfPresent(String.self, forKey: .channel),
      ]
      .compactMap { $0 }
      .first { !$0.isEmpty && $0 != "NA" } ?? "Unknown artist"

    duration = Self.decodeFlexibleDouble(container, key: .duration)

    if let explicit = try? container.decodeIfPresent(String.self, forKey: .webpageURL),
      !explicit.isEmpty,
      explicit != "NA"
    {
      webpageURLString = explicit
    } else if let rawURL = try? container.decodeIfPresent(String.self, forKey: .url),
      rawURL.hasPrefix("http")
    {
      webpageURLString = rawURL
    } else {
      webpageURLString = "https://www.youtube.com/watch?v=\(id)"
    }

    if let direct = try? container.decodeIfPresent(String.self, forKey: .thumbnail),
      !direct.isEmpty,
      direct != "NA"
    {
      thumbnailURLString = direct
    } else if let thumbnails = try? container.decodeIfPresent([Thumbnail].self, forKey: .thumbnails)
    {
      thumbnailURLString =
        thumbnails
        .filter { $0.url != nil }
        .max { ($0.width ?? 0) < ($1.width ?? 0) }?
        .url
    } else {
      thumbnailURLString = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(artist, forKey: .artist)
    try container.encodeIfPresent(duration, forKey: .duration)
    try container.encode(webpageURLString, forKey: .webpageURL)
    try container.encodeIfPresent(thumbnailURLString, forKey: .thumbnail)
  }

  private static func decodeFlexibleDouble(
    _ container: KeyedDecodingContainer<CodingKeys>,
    key: CodingKeys
  ) -> Double? {
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
      return value
    }
    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
      return Double(value)
    }
    return nil
  }
}

struct SearchEnvelope: Decodable {
  let entries: [SearchResult]
}
