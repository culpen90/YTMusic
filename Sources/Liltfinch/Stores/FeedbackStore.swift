import Foundation
import Observation

enum FeedbackStoreError: LocalizedError {
  case persistenceUnavailable

  var errorDescription: String? {
    "Rating changes are disabled because the existing feedback file could not be read."
  }
}

@MainActor
@Observable
final class FeedbackStore {
  private(set) var records: [SongFeedback] = []
  var errorMessage: String?

  private let metadataURL: URL
  private let metadataBackupURL: URL
  private let rootDirectory: URL
  private let now: () -> Date
  private var persistenceAvailable = true

  init(rootDirectory: URL, now: @escaping () -> Date = Date.init) {
    self.rootDirectory = rootDirectory.standardizedFileURL
    self.now = now
    metadataURL = self.rootDirectory.appendingPathComponent("feedback.json")
    metadataBackupURL = self.rootDirectory.appendingPathComponent("feedback.backup.json")
    guard Self.isSecureDirectory(self.rootDirectory) else {
      persistenceAvailable = false
      errorMessage =
        "Rating storage is disabled because Liltfinch's managed Library folder is unsafe."
      return
    }
    load()
  }

  func rating(for itemID: String) -> SongRating? {
    records.first { $0.id == itemID }?.rating
  }

  func rating(for item: SearchResult) -> SongRating? {
    rating(for: item.id)
  }

  var favoriteItems: [SearchResult] {
    records.compactMap { record in
      record.rating == .liked ? record.item : nil
    }
  }

  func setRating(_ rating: SongRating?, for item: SearchResult) {
    guard !item.id.isEmpty else { return }

    if let rating {
      if let existing = records.first(where: { $0.id == item.id }),
        existing.item == item,
        existing.rating == rating
      {
        return
      }
      let record = SongFeedback(item: item, rating: rating, updatedAt: now())
      commit {
        records.removeAll { $0.id == item.id }
        records.insert(record, at: 0)
      }
    } else {
      guard records.contains(where: { $0.id == item.id }) else { return }
      commit {
        records.removeAll { $0.id == item.id }
      }
    }
  }

  func rankedRecommendations(
    from candidates: [SearchResult],
    excluding excludedIDs: Set<String> = []
  ) -> [SearchResult] {
    let dislikedIDs = Set(
      records.lazy.filter { $0.rating == .disliked }.map(\.id)
    )
    let ratingsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.rating) })
    var artistAffinity: [String: Int] = [:]
    for record in records {
      guard let artist = Self.normalizedArtist(record.item.artist) else { continue }
      artistAffinity[artist, default: 0] += record.rating == .liked ? 1 : -1
    }

    var seenIDs = excludedIDs.union(dislikedIDs)
    var ranked: [(sourceIndex: Int, score: Int, item: SearchResult)] = []
    for (sourceIndex, item) in candidates.enumerated() {
      guard !item.id.isEmpty, seenIDs.insert(item.id).inserted else { continue }
      let exactLikeBonus = ratingsByID[item.id] == .liked ? 2 : 0
      let artistScore = Self.normalizedArtist(item.artist).flatMap { artistAffinity[$0] } ?? 0
      ranked.append((sourceIndex, exactLikeBonus + artistScore, item))
    }

    return ranked.sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      return $0.sourceIndex < $1.sourceIndex
    }.map(\.item)
  }

  private func load() {
    if Self.pathEntryExists(metadataURL) {
      guard Self.isManagedRegularFile(metadataURL, directlyInside: rootDirectory) else {
        disablePersistence("Feedback metadata is not a safe regular file.")
        return
      }
      do {
        records = try decodeRecords(from: metadataURL)
        return
      } catch {
        recoverFromBackup(after: error)
        return
      }
    }

    if Self.pathEntryExists(metadataBackupURL) {
      recoverFromBackup(after: nil)
    }
  }

  private func decodeRecords(from url: URL) throws -> [SongFeedback] {
    guard Self.isManagedRegularFile(url, directlyInside: rootDirectory) else {
      throw FeedbackStoreError.persistenceUnavailable
    }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([SongFeedback].self, from: data)

    var latestByID: [String: SongFeedback] = [:]
    for record in decoded where !record.id.isEmpty {
      guard let existing = latestByID[record.id] else {
        latestByID[record.id] = record
        continue
      }
      if record.updatedAt > existing.updatedAt {
        latestByID[record.id] = record
      }
    }
    return latestByID.values.sorted {
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return $0.id < $1.id
    }
  }

  private func recoverFromBackup(after primaryError: Error?) {
    guard Self.pathEntryExists(metadataBackupURL),
      Self.isManagedRegularFile(metadataBackupURL, directlyInside: rootDirectory)
    else {
      disablePersistence(
        primaryError.map {
          "Feedback could not be loaded and no valid backup was available: \($0.localizedDescription)"
        } ?? "Feedback metadata is missing and no valid backup was available."
      )
      return
    }

    do {
      let recovered = try decodeRecords(from: metadataBackupURL)
      if Self.pathEntryExists(metadataURL) {
        guard Self.isManagedRegularFile(metadataURL, directlyInside: rootDirectory) else {
          throw FeedbackStoreError.persistenceUnavailable
        }
        let quarantine = rootDirectory.appendingPathComponent(
          "feedback.corrupt.\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: metadataURL, to: quarantine)
      }
      let data = try encodedRecords(recovered)
      try data.write(to: metadataURL, options: .atomic)
      guard Self.isManagedRegularFile(metadataURL, directlyInside: rootDirectory) else {
        throw FeedbackStoreError.persistenceUnavailable
      }
      records = recovered
      errorMessage = "Ratings were restored from their last valid backup."
    } catch {
      disablePersistence(
        "Feedback could not be recovered and was preserved without replacement: \(error.localizedDescription)"
      )
    }
  }

  @discardableResult
  private func commit(_ mutation: () -> Void) -> Bool {
    guard persistenceAvailable else {
      errorMessage = FeedbackStoreError.persistenceUnavailable.localizedDescription
      return false
    }
    let previous = records
    mutation()
    do {
      try save()
      return true
    } catch {
      records = previous
      errorMessage = "Ratings could not be saved: \(error.localizedDescription)"
      return false
    }
  }

  private func save() throws {
    guard persistenceAvailable, Self.isSecureDirectory(rootDirectory) else {
      throw FeedbackStoreError.persistenceUnavailable
    }
    guard
      !Self.pathEntryExists(metadataURL)
        || Self.isManagedRegularFile(metadataURL, directlyInside: rootDirectory),
      !Self.pathEntryExists(metadataBackupURL)
        || Self.isManagedRegularFile(metadataBackupURL, directlyInside: rootDirectory)
    else { throw FeedbackStoreError.persistenceUnavailable }
    let data = try encodedRecords(records)
    try data.write(to: metadataURL, options: .atomic)
    try? data.write(to: metadataBackupURL, options: .atomic)
  }

  private func encodedRecords(_ records: [SongFeedback]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(records)
  }

  private func disablePersistence(_ message: String) {
    records = []
    persistenceAvailable = false
    errorMessage = message
  }

  private static func normalizedArtist(_ value: String) -> String? {
    let locale = Locale(identifier: "en_US_POSIX")
    var normalized =
      value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
      .lowercased(with: locale)
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    if normalized.hasSuffix(" - topic") {
      normalized.removeLast(" - topic".count)
      normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !normalized.isEmpty,
      !["unknown", "unknown artist", "youtube"].contains(normalized)
    else { return nil }
    return normalized
  }

  private static func pathEntryExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
      || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private static func isSecureDirectory(_ url: URL) -> Bool {
    let candidate = url.standardizedFileURL
    guard candidate.resolvingSymlinksInPath().path == candidate.path,
      let values = try? candidate.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private static func isManagedRegularFile(_ url: URL, directlyInside directory: URL) -> Bool {
    let root = directory.standardizedFileURL
    let candidate = url.standardizedFileURL
    guard isSecureDirectory(root),
      candidate.deletingLastPathComponent() == root,
      candidate.resolvingSymlinksInPath().path == candidate.path,
      let values = try? candidate.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }
}
