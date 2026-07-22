import Foundation

enum SongRating: String, Codable, Hashable, Sendable {
  case liked
  case disliked
}

struct SongFeedback: Identifiable, Codable, Hashable, Sendable {
  let item: SearchResult
  let rating: SongRating
  let updatedAt: Date

  var id: String { item.id }
}
