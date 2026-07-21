import Foundation

enum TrackStorage: String, Codable, Hashable {
  case temporary
  case library
}

struct Track: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var artist: String
  var duration: Double?
  var sourceURLString: String
  var thumbnailURLString: String?
  var localFilePath: String
  var localArtworkFilePath: String?
  var storage: TrackStorage
  var format: String
  var fileSize: Int64?
  var dateAdded: Date
  var lastPlayedAt: Date?
  var playCount: Int

  var sourceURL: URL? { URL(string: sourceURLString) }
  var thumbnailURL: URL? { thumbnailURLString.flatMap(URL.init(string:)) }

  var audioURL: URL {
    URL(fileURLWithPath: localFilePath)
  }

  var artworkURL: URL? {
    localArtworkFilePath.map(URL.init(fileURLWithPath:))
  }

  var searchResult: SearchResult {
    SearchResult(
      id: id,
      title: title,
      artist: artist,
      duration: duration,
      webpageURLString: sourceURLString,
      thumbnailURLString: thumbnailURLString
    )
  }
}
