import Foundation
import Observation

enum PlaylistStoreError: LocalizedError {
  case persistenceUnavailable

  var errorDescription: String? {
    "Playlist changes are disabled because the existing playlist file could not be read."
  }
}

@MainActor
@Observable
final class PlaylistStore {
  private(set) var playlists: [Playlist] = []
  var errorMessage: String?

  private let metadataURL: URL
  private let metadataBackupURL: URL
  private let rootDirectory: URL
  private var persistenceAvailable = true

  init(rootDirectory: URL) {
    self.rootDirectory = rootDirectory.standardizedFileURL
    metadataURL = rootDirectory.appendingPathComponent("playlists.json")
    metadataBackupURL = rootDirectory.appendingPathComponent("playlists.backup.json")
    guard Self.isSecureDirectory(self.rootDirectory) else {
      persistenceAvailable = false
      errorMessage =
        "Playlist storage is disabled because YTMusic's managed Library folder is unsafe."
      return
    }
    load()
  }

  @discardableResult
  func create(name: String) -> UUID? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let playlist = Playlist(name: trimmed.isEmpty ? "New Playlist" : trimmed)
    return commit {
      playlists.append(playlist)
    } ? playlist.id : nil
  }

  func playlist(id: UUID) -> Playlist? {
    playlists.first { $0.id == id }
  }

  func add(_ item: SearchResult, to playlistID: UUID) {
    add([item], to: playlistID)
  }

  func add(_ items: [SearchResult], to playlistID: UUID) {
    guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
    var seenIDs = Set(playlists[index].items.map(\.id))
    let newItems = items.filter { seenIDs.insert($0.id).inserted }
    guard !newItems.isEmpty else { return }
    commit {
      playlists[index].items.append(contentsOf: newItems)
      playlists[index].updatedAt = Date()
    }
  }

  func removeItem(id itemID: String, from playlistID: UUID) {
    guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
      playlists[index].items.contains(where: { $0.id == itemID })
    else { return }
    commit {
      playlists[index].items.removeAll { $0.id == itemID }
      playlists[index].updatedAt = Date()
    }
  }

  func moveItems(from offsets: IndexSet, to destination: Int, in playlistID: UUID) {
    guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
    commit {
      playlists[index].items.move(fromOffsets: offsets, toOffset: destination)
      playlists[index].updatedAt = Date()
    }
  }

  func rename(_ playlistID: UUID, to name: String) {
    guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, playlists[index].name != trimmed else { return }
    commit {
      playlists[index].name = trimmed
      playlists[index].updatedAt = Date()
    }
  }

  func delete(_ playlistID: UUID) {
    guard playlists.contains(where: { $0.id == playlistID }) else { return }
    commit {
      playlists.removeAll { $0.id == playlistID }
    }
  }

  private func load() {
    if Self.pathEntryExists(metadataURL) {
      guard Self.isManagedRegularFile(metadataURL, directlyInside: rootDirectory) else {
        disablePersistence("Playlist metadata is not a safe regular file.")
        return
      }
      do {
        playlists = try decodePlaylists(from: metadataURL)
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

  private func decodePlaylists(from url: URL) throws -> [Playlist] {
    guard Self.isManagedRegularFile(url, directlyInside: rootDirectory) else {
      throw PlaylistStoreError.persistenceUnavailable
    }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([Playlist].self, from: data)
  }

  private func recoverFromBackup(after primaryError: Error?) {
    guard Self.pathEntryExists(metadataBackupURL),
      Self.isManagedRegularFile(metadataBackupURL, directlyInside: rootDirectory)
    else {
      disablePersistence(
        primaryError.map {
          "Playlists could not be loaded and no valid backup was available: \($0.localizedDescription)"
        } ?? "Playlist metadata is missing and no valid backup was available."
      )
      return
    }

    do {
      let recovered = try decodePlaylists(from: metadataBackupURL)
      if Self.pathEntryExists(metadataURL) {
        guard Self.isManagedRegularFile(metadataURL, directlyInside: rootDirectory) else {
          throw PlaylistStoreError.persistenceUnavailable
        }
        let quarantine = rootDirectory.appendingPathComponent(
          "playlists.corrupt.\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: metadataURL, to: quarantine)
      }
      let data = try encodedPlaylists(recovered)
      try data.write(to: metadataURL, options: .atomic)
      guard Self.isManagedRegularFile(metadataURL, directlyInside: rootDirectory) else {
        throw PlaylistStoreError.persistenceUnavailable
      }
      playlists = recovered
      errorMessage = "Playlists were restored from their last valid backup."
    } catch {
      disablePersistence(
        "Playlists could not be recovered and were preserved without replacement: \(error.localizedDescription)"
      )
    }
  }

  @discardableResult
  private func commit(_ mutation: () -> Void) -> Bool {
    guard persistenceAvailable else {
      errorMessage = PlaylistStoreError.persistenceUnavailable.localizedDescription
      return false
    }
    let previous = playlists
    mutation()
    do {
      try save()
      return true
    } catch {
      playlists = previous
      errorMessage = "Playlists could not be saved: \(error.localizedDescription)"
      return false
    }
  }

  private func save() throws {
    guard persistenceAvailable, Self.isSecureDirectory(rootDirectory) else {
      throw PlaylistStoreError.persistenceUnavailable
    }
    guard
      !Self.pathEntryExists(metadataURL)
        || Self.isManagedRegularFile(metadataURL, directlyInside: rootDirectory),
      !Self.pathEntryExists(metadataBackupURL)
        || Self.isManagedRegularFile(metadataBackupURL, directlyInside: rootDirectory)
    else { throw PlaylistStoreError.persistenceUnavailable }
    let data = try encodedPlaylists(playlists)
    try data.write(to: metadataURL, options: .atomic)
    try? data.write(to: metadataBackupURL, options: .atomic)
  }

  private func encodedPlaylists(_ playlists: [Playlist]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(playlists)
  }

  private func disablePersistence(_ message: String) {
    playlists = []
    persistenceAvailable = false
    errorMessage = message
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
