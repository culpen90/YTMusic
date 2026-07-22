import AppKit
import Foundation
import Observation

enum LibraryError: LocalizedError {
  case invalidArtifact
  case unsafeStorage
  case persistenceUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidArtifact:
      "The completed audio file could not be imported safely."
    case .unsafeStorage:
      "Liltfinch stopped because one of its managed storage folders is unsafe or unavailable."
    case .persistenceUnavailable:
      "Library changes are disabled because the existing library metadata could not be read."
    }
  }
}

@MainActor
@Observable
final class LibraryStore {
  private(set) var tracks: [Track] = []
  var errorMessage: String?

  let rootDirectory: URL
  let mediaDirectory: URL
  let artworkDirectory: URL
  let recoveryDirectory: URL
  let cacheDirectory: URL
  let stagingDirectory: URL
  let temporaryPlaybackDirectory: URL

  private let fileManager: FileManager
  private let legacyRootDirectory: URL?
  private let metadataURL: URL
  private let metadataBackupURL: URL
  private var persistenceAvailable = true

  init(
    fileManager: FileManager = .default,
    rootOverride: URL? = nil,
    cacheOverride: URL? = nil,
    applicationSupportDirectoryOverride: URL? = nil,
    cachesDirectoryOverride: URL? = nil
  ) {
    self.fileManager = fileManager
    let appSupport =
      applicationSupportDirectoryOverride
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let storageResolution =
      rootOverride.map {
        AppStorageResolution(rootDirectory: $0, legacyRootDirectory: nil, warning: nil)
      }
      ?? AppMigration.resolveApplicationSupportRoot(
        fileManager: fileManager,
        baseDirectory: appSupport)
    rootDirectory = storageResolution.rootDirectory
    legacyRootDirectory = storageResolution.legacyRootDirectory
    mediaDirectory = rootDirectory.appendingPathComponent("Media", isDirectory: true)
    artworkDirectory = rootDirectory.appendingPathComponent("Artwork", isDirectory: true)
    recoveryDirectory = rootDirectory.appendingPathComponent("Recovered", isDirectory: true)
    metadataURL = rootDirectory.appendingPathComponent("library.json")
    metadataBackupURL = rootDirectory.appendingPathComponent("library.backup.json")

    let caches =
      cachesDirectoryOverride
      ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    cacheDirectory =
      cacheOverride
      ?? AppMigration.resolveCacheRoot(
        fileManager: fileManager,
        baseDirectory: caches)
    stagingDirectory = cacheDirectory.appendingPathComponent("Staging", isDirectory: true)
    temporaryPlaybackDirectory = cacheDirectory.appendingPathComponent(
      "PlayOnce", isDirectory: true)

    do {
      try prepareDirectories()
      cleanupAllTemporaryFiles()
    } catch {
      persistenceAvailable = false
      errorMessage = error.localizedDescription
      return
    }
    load()
    if persistenceAvailable, legacyRootDirectory != nil {
      do {
        try finalizeLegacyMetadataMigration()
      } catch {
        persistenceAvailable = false
        errorMessage =
          "The legacy Library metadata could not be migrated safely: \(error.localizedDescription)"
        return
      }
    }
    if persistenceAvailable {
      do {
        try AppMigration.completeStorageMigration(
          fileManager: fileManager,
          rootDirectory: rootDirectory)
      } catch {
        errorMessage = "The storage migration could not be finalized: \(error.localizedDescription)"
      }
    }
    reconcileOrphanedFiles()
    if errorMessage == nil {
      errorMessage = storageResolution.warning
    }
  }

  var totalSize: Int64 {
    tracks.compactMap(\.fileSize).reduce(0, +)
  }

  func contains(_ sourceID: String) -> Bool {
    tracks.contains { $0.id == sourceID }
  }

  func track(withID sourceID: String) -> Track? {
    tracks.first { $0.id == sourceID }
  }

  func makeStagingDirectory(jobID: UUID) throws -> URL {
    guard isSecureDirectory(stagingDirectory) else { throw LibraryError.unsafeStorage }
    let url = stagingDirectory.appendingPathComponent(jobID.uuidString, isDirectory: true)
    guard !pathEntryExists(url) else { throw LibraryError.unsafeStorage }
    try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    guard isManagedDirectory(url, directlyInside: stagingDirectory) else {
      throw LibraryError.unsafeStorage
    }
    return url
  }

  func importArtifact(
    _ artifact: DownloadArtifact,
    intent: DownloadIntent,
    jobID: UUID
  ) throws -> Track {
    let staging = artifact.stagingDirectory.standardizedFileURL
    let expectedStaging =
      stagingDirectory
      .appendingPathComponent(jobID.uuidString, isDirectory: true)
      .standardizedFileURL
    let sourceAudio = URL(fileURLWithPath: artifact.output.filepath).standardizedFileURL

    guard staging == expectedStaging,
      isManagedDirectory(staging, directlyInside: stagingDirectory),
      artifact.output.id == artifact.metadata.id,
      sourceAudio.deletingLastPathComponent() == staging,
      sourceAudio.deletingPathExtension().lastPathComponent == artifact.metadata.id,
      isManagedRegularFile(sourceAudio, directlyInside: staging)
    else {
      throw LibraryError.invalidArtifact
    }

    if intent == .keep, let existing = track(withID: artifact.metadata.id) {
      removeStagingDirectory(staging)
      return existing
    }

    let artworkCandidates = try fileManager.contentsOfDirectory(
      at: staging,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    ).filter {
      $0.deletingPathExtension().lastPathComponent == artifact.metadata.id
        && ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased())
    }
    guard artworkCandidates.allSatisfy({ isManagedRegularFile($0, directlyInside: staging) }) else {
      throw LibraryError.invalidArtifact
    }
    let artworkSource = artworkCandidates.first

    let destinationFolder: URL
    let artworkDestinationFolder: URL
    switch intent {
    case .keep:
      guard isSecureDirectory(mediaDirectory), isSecureDirectory(artworkDirectory) else {
        throw LibraryError.unsafeStorage
      }
      destinationFolder = mediaDirectory
      artworkDestinationFolder = artworkDirectory
    case .playOnce:
      guard isSecureDirectory(temporaryPlaybackDirectory) else {
        throw LibraryError.unsafeStorage
      }
      destinationFolder = temporaryPlaybackDirectory.appendingPathComponent(
        jobID.uuidString, isDirectory: true)
      guard !pathEntryExists(destinationFolder) else { throw LibraryError.unsafeStorage }
      try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: false)
      guard isManagedDirectory(destinationFolder, directlyInside: temporaryPlaybackDirectory) else {
        throw LibraryError.unsafeStorage
      }
      artworkDestinationFolder = destinationFolder
    }

    let audioDestination = destinationFolder.appendingPathComponent(sourceAudio.lastPathComponent)
    let artworkDestination = artworkSource.map {
      artworkDestinationFolder.appendingPathComponent($0.lastPathComponent)
    }
    guard !pathEntryExists(audioDestination),
      artworkDestination.map({ !pathEntryExists($0) }) ?? true
    else { throw LibraryError.invalidArtifact }

    let previousTracks = tracks
    var audioWasMoved = false
    var artworkWasMoved = false
    do {
      try fileManager.moveItem(at: sourceAudio, to: audioDestination)
      audioWasMoved = true
      guard isManagedRegularFile(audioDestination, directlyInside: destinationFolder) else {
        throw LibraryError.invalidArtifact
      }

      if let artworkSource, let artworkDestination {
        try fileManager.moveItem(at: artworkSource, to: artworkDestination)
        artworkWasMoved = true
        guard isManagedRegularFile(artworkDestination, directlyInside: artworkDestinationFolder)
        else {
          throw LibraryError.invalidArtifact
        }
      }

      let attributes = try? fileManager.attributesOfItem(atPath: audioDestination.path)
      let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
      let track = Track(
        id: artifact.metadata.id,
        title: artifact.metadata.title,
        artist: artifact.metadata.artist,
        duration: artifact.metadata.duration,
        sourceURLString: artifact.metadata.webpageURLString,
        thumbnailURLString: artifact.metadata.thumbnailURLString,
        localFilePath: audioDestination.path,
        localArtworkFilePath: artworkDestination?.path,
        storage: intent == .keep ? .library : .temporary,
        format: artifact.output.ext ?? audioDestination.pathExtension,
        fileSize: fileSize,
        dateAdded: Date(),
        lastPlayedAt: nil,
        playCount: 0
      )

      try fileManager.removeItem(at: staging)
      if intent == .keep {
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        try save()
      }
      return track
    } catch {
      tracks = previousTracks
      if artworkWasMoved, let artworkDestination {
        try? fileManager.removeItem(at: artworkDestination)
      }
      if audioWasMoved {
        try? fileManager.removeItem(at: audioDestination)
      }
      if intent == .playOnce {
        try? fileManager.removeItem(at: destinationFolder)
      }
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func markPlayed(_ track: Track) {
    guard track.storage == .library,
      let index = tracks.firstIndex(where: { $0.id == track.id })
    else { return }
    let previous = tracks[index]
    tracks[index].lastPlayedAt = Date()
    tracks[index].playCount += 1
    do {
      try save()
    } catch {
      tracks[index] = previous
      errorMessage = error.localizedDescription
    }
  }

  func deleteFromLibrary(_ track: Track) {
    guard track.storage == .library,
      let storedTrack = tracks.first(where: { $0.id == track.id })
    else {
      errorMessage = "The selected track is not part of the managed Library."
      return
    }
    guard isManagedRegularFile(storedTrack.audioURL, directlyInside: mediaDirectory),
      storedTrack.audioURL.deletingPathExtension().lastPathComponent == storedTrack.id
    else {
      errorMessage = "Refused to delete an audio file outside the managed Library folder."
      return
    }

    let previousTracks = tracks
    tracks.removeAll { $0.id == track.id }
    do {
      try save()
      var resultingURL: NSURL?
      try fileManager.trashItem(at: storedTrack.audioURL, resultingItemURL: &resultingURL)
      if let artworkURL = storedTrack.artworkURL,
        isManagedRegularFile(artworkURL, directlyInside: artworkDirectory)
      {
        try? fileManager.removeItem(at: artworkURL)
      }
    } catch {
      tracks = previousTracks
      try? save()
      errorMessage = error.localizedDescription
    }
  }

  func deleteTemporaryTrack(_ track: Track) {
    guard track.storage == .temporary else { return }
    let folder = track.audioURL.deletingLastPathComponent().standardizedFileURL
    guard pathEntryExists(folder) else { return }
    guard isManagedDirectory(folder, directlyInside: temporaryPlaybackDirectory) else {
      errorMessage = "Refused to remove a temporary file outside Liltfinch's cache."
      return
    }
    do {
      try fileManager.removeItem(at: folder)
    } catch {
      errorMessage = "Temporary audio could not be deleted: \(error.localizedDescription)"
    }
  }

  func removeStagingDirectory(_ url: URL) {
    let standardized = url.standardizedFileURL
    guard pathEntryExists(standardized) else { return }
    guard isManagedDirectory(standardized, directlyInside: stagingDirectory) else {
      errorMessage = "Refused to remove a staging folder outside Liltfinch's cache."
      return
    }
    do {
      try fileManager.removeItem(at: standardized)
    } catch {
      errorMessage = "Temporary download files could not be deleted: \(error.localizedDescription)"
    }
  }

  func cleanupAllTemporaryFiles() {
    guard isSecureDirectory(cacheDirectory) else {
      errorMessage = LibraryError.unsafeStorage.localizedDescription
      return
    }
    do {
      for directory in [stagingDirectory, temporaryPlaybackDirectory] {
        if pathEntryExists(directory) {
          guard isManagedDirectory(directory, directlyInside: cacheDirectory) else {
            throw LibraryError.unsafeStorage
          }
          try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        guard isManagedDirectory(directory, directlyInside: cacheDirectory) else {
          throw LibraryError.unsafeStorage
        }
      }
    } catch {
      errorMessage = "Temporary files could not be cleaned: \(error.localizedDescription)"
    }
  }

  private func prepareDirectories() throws {
    try createSecureDirectory(rootDirectory)
    try createSecureDirectory(mediaDirectory)
    try createSecureDirectory(artworkDirectory)
    try createSecureDirectory(recoveryDirectory)
    try createSecureDirectory(cacheDirectory)
    try createSecureDirectory(stagingDirectory)
    try createSecureDirectory(temporaryPlaybackDirectory)
  }

  private func createSecureDirectory(_ directory: URL) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    guard isSecureDirectory(directory) else { throw LibraryError.unsafeStorage }
  }

  private func load() {
    if pathEntryExists(metadataURL) {
      guard isManagedRegularFile(metadataURL, directlyInside: rootDirectory) else {
        disablePersistence("Library metadata is not a safe regular file.")
        return
      }
      do {
        let result = try decodeTracks(from: metadataURL)
        tracks = result.tracks
        if result.requiresSave { try save() }
        return
      } catch {
        recoverFromBackup(after: error)
        return
      }
    }

    if pathEntryExists(metadataBackupURL) {
      recoverFromBackup(after: nil)
    }
  }

  private func decodeTracks(from url: URL) throws -> (
    tracks: [Track], requiresSave: Bool
  ) {
    guard isManagedRegularFile(url, directlyInside: rootDirectory) else {
      throw LibraryError.unsafeStorage
    }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([Track].self, from: data)
    var seenIDs = Set<String>()
    var seenAudioPaths = Set<String>()
    var seenArtworkPaths = Set<String>()
    var safeTracks: [Track] = []
    var migratedLegacyPaths = false
    for decodedTrack in decoded {
      var track = decodedTrack
      if let migratedAudioPath = migratedManagedPath(
        track.localFilePath,
        legacySubdirectory: "Media",
        currentDirectory: mediaDirectory)
      {
        track.localFilePath = migratedAudioPath
        migratedLegacyPaths = true
      }
      if let artworkPath = track.localArtworkFilePath,
        let migratedArtworkPath = migratedManagedPath(
          artworkPath,
          legacySubdirectory: "Artwork",
          currentDirectory: artworkDirectory)
      {
        track.localArtworkFilePath = migratedArtworkPath
        migratedLegacyPaths = true
      }

      let canonicalAudioPath = track.audioURL.resolvingSymlinksInPath().path
      guard track.storage == .library,
        track.audioURL.deletingPathExtension().lastPathComponent == track.id,
        isManagedRegularFile(track.audioURL, directlyInside: mediaDirectory),
        seenIDs.insert(track.id).inserted,
        seenAudioPaths.insert(canonicalAudioPath).inserted
      else { continue }
      if let artworkURL = track.artworkURL {
        let canonicalArtworkPath = artworkURL.resolvingSymlinksInPath().path
        if !isManagedRegularFile(artworkURL, directlyInside: artworkDirectory)
          || !seenArtworkPaths.insert(canonicalArtworkPath).inserted
        {
          track.localArtworkFilePath = nil
        }
      }
      safeTracks.append(track)
    }
    return (safeTracks, safeTracks.count != decoded.count || migratedLegacyPaths)
  }

  private func migratedManagedPath(
    _ path: String,
    legacySubdirectory: String,
    currentDirectory: URL
  ) -> String? {
    guard let legacyRootDirectory else { return nil }
    let legacyDirectory = legacyRootDirectory.appendingPathComponent(
      legacySubdirectory, isDirectory: true
    ).standardizedFileURL
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    guard candidate.deletingLastPathComponent() == legacyDirectory else { return nil }
    return currentDirectory.appendingPathComponent(candidate.lastPathComponent).path
  }

  private func recoverFromBackup(after primaryError: Error?) {
    guard pathEntryExists(metadataBackupURL),
      isManagedRegularFile(metadataBackupURL, directlyInside: rootDirectory)
    else {
      disablePersistence(
        primaryError.map {
          "Library metadata could not be loaded and no valid backup was available: \($0.localizedDescription)"
        } ?? "Library metadata is missing and no valid backup was available."
      )
      return
    }

    do {
      let recoveryResult = try decodeTracks(from: metadataBackupURL)
      let recovered = recoveryResult.tracks
      if pathEntryExists(metadataURL) {
        guard isManagedRegularFile(metadataURL, directlyInside: rootDirectory) else {
          throw LibraryError.unsafeStorage
        }
        let quarantine = rootDirectory.appendingPathComponent(
          "library.corrupt.\(UUID().uuidString).json")
        try fileManager.moveItem(at: metadataURL, to: quarantine)
      }
      let data = try encodedTracks(recovered)
      try data.write(to: metadataURL, options: .atomic)
      guard isManagedRegularFile(metadataURL, directlyInside: rootDirectory) else {
        throw LibraryError.unsafeStorage
      }
      if recoveryResult.requiresSave {
        try data.write(to: metadataBackupURL, options: .atomic)
        guard isManagedRegularFile(metadataBackupURL, directlyInside: rootDirectory) else {
          throw LibraryError.unsafeStorage
        }
      }
      tracks = recovered
      errorMessage = "Library metadata was restored from its last valid backup."
    } catch {
      disablePersistence(
        "Library metadata could not be recovered and was preserved without replacement: \(error.localizedDescription)"
      )
    }
  }

  private func save() throws {
    guard persistenceAvailable, isSecureDirectory(rootDirectory), isSecureDirectory(mediaDirectory),
      isSecureDirectory(artworkDirectory)
    else { throw LibraryError.persistenceUnavailable }
    do {
      guard
        !pathEntryExists(metadataURL)
          || isManagedRegularFile(metadataURL, directlyInside: rootDirectory),
        !pathEntryExists(metadataBackupURL)
          || isManagedRegularFile(metadataBackupURL, directlyInside: rootDirectory)
      else { throw LibraryError.unsafeStorage }
      let data = try encodedTracks(tracks)
      try data.write(to: metadataURL, options: .atomic)
      try? data.write(to: metadataBackupURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  private func finalizeLegacyMetadataMigration() throws {
    guard pathEntryExists(metadataURL) || pathEntryExists(metadataBackupURL) else { return }
    guard persistenceAvailable, isSecureDirectory(rootDirectory), isSecureDirectory(mediaDirectory),
      isSecureDirectory(artworkDirectory)
    else { throw LibraryError.persistenceUnavailable }

    let data = try encodedTracks(tracks)
    for url in [metadataURL, metadataBackupURL] {
      guard !pathEntryExists(url) || isManagedRegularFile(url, directlyInside: rootDirectory) else {
        throw LibraryError.unsafeStorage
      }
      try data.write(to: url, options: .atomic)
      guard isManagedRegularFile(url, directlyInside: rootDirectory) else {
        throw LibraryError.unsafeStorage
      }
    }
  }

  private func reconcileOrphanedFiles() {
    guard persistenceAvailable, isSecureDirectory(mediaDirectory),
      isSecureDirectory(artworkDirectory), isSecureDirectory(recoveryDirectory)
    else { return }
    let referencedAudio = Set(tracks.map { $0.audioURL.standardizedFileURL.path })
    let referencedArtwork = Set(
      tracks.compactMap { $0.artworkURL?.standardizedFileURL.path })
    var movedFiles = false
    do {
      for url in try fileManager.contentsOfDirectory(
        at: mediaDirectory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      ) where !referencedAudio.contains(url.standardizedFileURL.path) {
        guard isManagedRegularFile(url, directlyInside: mediaDirectory) else { continue }
        try moveToRecovery(url)
        movedFiles = true
      }
      for url in try fileManager.contentsOfDirectory(
        at: artworkDirectory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      ) where !referencedArtwork.contains(url.standardizedFileURL.path) {
        guard isManagedRegularFile(url, directlyInside: artworkDirectory) else { continue }
        try moveToRecovery(url)
        movedFiles = true
      }
      if movedFiles {
        errorMessage =
          "Files not referenced by Library metadata were preserved in \(recoveryDirectory.path)."
      }
    } catch {
      errorMessage =
        "Incomplete Library files could not be reconciled: \(error.localizedDescription)"
    }
  }

  private func moveToRecovery(_ url: URL) throws {
    let destination = recoveryDirectory.appendingPathComponent(
      "\(UUID().uuidString)-\(url.lastPathComponent)")
    guard !pathEntryExists(destination) else { throw LibraryError.unsafeStorage }
    try fileManager.moveItem(at: url, to: destination)
    guard isManagedRegularFile(destination, directlyInside: recoveryDirectory) else {
      throw LibraryError.unsafeStorage
    }
  }

  private func encodedTracks(_ tracks: [Track]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(tracks)
  }

  private func disablePersistence(_ message: String) {
    tracks = []
    persistenceAvailable = false
    errorMessage = message
  }

  private func pathEntryExists(_ url: URL) -> Bool {
    fileManager.fileExists(atPath: url.path)
      || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private func isSecureDirectory(_ url: URL) -> Bool {
    let candidate = url.standardizedFileURL
    guard candidate.resolvingSymlinksInPath().path == candidate.path,
      let values = try? candidate.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private func isManagedDirectory(_ url: URL, directlyInside directory: URL) -> Bool {
    let root = directory.standardizedFileURL
    let candidate = url.standardizedFileURL
    return isSecureDirectory(root)
      && candidate.deletingLastPathComponent() == root
      && isSecureDirectory(candidate)
  }

  private func isManagedRegularFile(_ url: URL, directlyInside directory: URL) -> Bool {
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
