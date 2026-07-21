import Foundation

struct Playlist: Identifiable, Codable, Hashable {
  let id: UUID
  var name: String
  var items: [SearchResult]
  let createdAt: Date
  var updatedAt: Date

  init(id: UUID = UUID(), name: String, items: [SearchResult] = []) {
    self.id = id
    self.name = name
    self.items = items
    createdAt = Date()
    updatedAt = Date()
  }
}
