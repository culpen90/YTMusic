import XCTest

@testable import Liltfinch

@MainActor
final class AppMigrationTests: XCTestCase {
  private var baseDirectory: URL!
  private var applicationSupportDirectory: URL!
  private var cachesDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LiltfinchMigrationTests-\(UUID().uuidString)", isDirectory: true)
    applicationSupportDirectory = baseDirectory.appendingPathComponent(
      "Application Support", isDirectory: true)
    cachesDirectory = baseDirectory.appendingPathComponent("Caches", isDirectory: true)
    try FileManager.default.createDirectory(
      at: applicationSupportDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let baseDirectory {
      try? FileManager.default.removeItem(at: baseDirectory)
    }
    try super.tearDownWithError()
  }

  func testLegacyStorageMovesAndRewritesManagedTrackPaths() throws {
    let fixture = try makeLegacyLibrary()
    let legacyRoot = fixture.store.rootDirectory
    let legacyCache = fixture.store.cacheDirectory
    let playlistStore = PlaylistStore(rootDirectory: legacyRoot)
    let playlistID = try XCTUnwrap(playlistStore.create(name: "Migration Mix"))
    playlistStore.add(fixture.item, to: playlistID)
    let feedbackStore = FeedbackStore(rootDirectory: legacyRoot)
    feedbackStore.setRating(.liked, for: fixture.item)
    let recoveryMarker = fixture.store.recoveryDirectory.appendingPathComponent("preserved.txt")
    try Data("preserve me".utf8).write(to: recoveryMarker)

    let migrated = LibraryStore(
      applicationSupportDirectoryOverride: applicationSupportDirectory,
      cachesDirectoryOverride: cachesDirectory)
    let currentRoot = applicationSupportDirectory.appendingPathComponent(
      AppIdentity.name, isDirectory: true)
    let currentCache = cachesDirectory.appendingPathComponent(
      AppIdentity.name, isDirectory: true)

    XCTAssertEqual(migrated.rootDirectory, currentRoot)
    XCTAssertEqual(migrated.cacheDirectory, currentCache)
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyCache.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: currentRoot.appendingPathComponent(
          AppIdentity.storageMigrationCompleteFilename
        ).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: currentRoot.appendingPathComponent(
          AppIdentity.storageMigrationPendingFilename
        ).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: recoveryMarker.path.replacingOccurrences(
          of: legacyRoot.path, with: currentRoot.path)))

    let track = try XCTUnwrap(migrated.track(withID: fixture.item.id))
    XCTAssertEqual(track.audioURL.deletingLastPathComponent(), migrated.mediaDirectory)
    XCTAssertEqual(track.artworkURL?.deletingLastPathComponent(), migrated.artworkDirectory)
    XCTAssertTrue(FileManager.default.fileExists(atPath: track.audioURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(track.artworkURL).path))

    for filename in ["library.json", "library.backup.json"] {
      let persistedTrack = try XCTUnwrap(
        decodeTracks(at: currentRoot.appendingPathComponent(filename)).first)
      XCTAssertEqual(
        persistedTrack.audioURL.deletingLastPathComponent(), migrated.mediaDirectory)
      XCTAssertEqual(
        persistedTrack.artworkURL?.deletingLastPathComponent(), migrated.artworkDirectory)
    }

    let migratedPlaylists = PlaylistStore(rootDirectory: currentRoot)
    XCTAssertEqual(migratedPlaylists.playlist(id: playlistID)?.items.first, fixture.item)
    let migratedFeedback = FeedbackStore(rootDirectory: currentRoot)
    XCTAssertEqual(migratedFeedback.rating(for: fixture.item), .liked)
  }

  func testCorruptPrimaryRecoversFromRewrittenBackupAfterStorageMove() throws {
    let fixture = try makeLegacyLibrary()
    let legacyRoot = fixture.store.rootDirectory
    try Data("corrupt".utf8).write(to: legacyRoot.appendingPathComponent("library.json"))

    let migrated = LibraryStore(
      applicationSupportDirectoryOverride: applicationSupportDirectory,
      cachesDirectoryOverride: cachesDirectory)
    let track = try XCTUnwrap(migrated.track(withID: fixture.item.id))

    XCTAssertEqual(track.audioURL.deletingLastPathComponent(), migrated.mediaDirectory)
    for filename in ["library.json", "library.backup.json"] {
      let persistedTrack = try XCTUnwrap(
        decodeTracks(at: migrated.rootDirectory.appendingPathComponent(filename)).first)
      XCTAssertEqual(
        persistedTrack.audioURL.deletingLastPathComponent(), migrated.mediaDirectory)
    }
  }

  func testInterruptedMigrationRefreshesBackupBeforeClearingPendingState() throws {
    let fixture = try makeLegacyLibrary()
    let legacyRoot = fixture.store.rootDirectory
    let currentRoot = applicationSupportDirectory.appendingPathComponent(
      AppIdentity.name, isDirectory: true)
    var primaryTracks = try decodeTracks(
      at: legacyRoot.appendingPathComponent("library.json"))
    primaryTracks[0].localFilePath =
      currentRoot.appendingPathComponent(
        "Media", isDirectory: true
      ).appendingPathComponent(primaryTracks[0].audioURL.lastPathComponent).path
    if let artworkFilename = primaryTracks[0].artworkURL?.lastPathComponent {
      primaryTracks[0].localArtworkFilePath =
        currentRoot.appendingPathComponent(
          "Artwork", isDirectory: true
        ).appendingPathComponent(artworkFilename).path
    }

    try FileManager.default.moveItem(at: legacyRoot, to: currentRoot)
    try encodeTracks(primaryTracks).write(
      to: currentRoot.appendingPathComponent("library.json"), options: .atomic)
    try Data("1\n".utf8).write(
      to: currentRoot.appendingPathComponent(AppIdentity.storageMigrationPendingFilename),
      options: .atomic)

    let migrated = LibraryStore(
      applicationSupportDirectoryOverride: applicationSupportDirectory,
      cachesDirectoryOverride: cachesDirectory)
    XCTAssertNotNil(migrated.track(withID: fixture.item.id))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: currentRoot.appendingPathComponent(
          AppIdentity.storageMigrationPendingFilename
        ).path))
    let migratedBackupTrack = try XCTUnwrap(
      decodeTracks(at: currentRoot.appendingPathComponent("library.backup.json")).first)
    XCTAssertEqual(
      migratedBackupTrack.audioURL.deletingLastPathComponent(), migrated.mediaDirectory)

    try Data("corrupt".utf8).write(
      to: currentRoot.appendingPathComponent("library.json"), options: .atomic)
    let recovered = LibraryStore(
      applicationSupportDirectoryOverride: applicationSupportDirectory,
      cachesDirectoryOverride: cachesDirectory)
    XCTAssertNotNil(recovered.track(withID: fixture.item.id))
    XCTAssertEqual(
      recovered.track(withID: fixture.item.id)?.audioURL.deletingLastPathComponent(),
      recovered.mediaDirectory)
  }

  func testUnsafeLegacyRootIsLeftUntouched() throws {
    let externalRoot = baseDirectory.appendingPathComponent("External", isDirectory: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    let marker = externalRoot.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: marker)
    let legacyRoot = applicationSupportDirectory.appendingPathComponent(
      AppIdentity.legacyName, isDirectory: true)
    try FileManager.default.createSymbolicLink(at: legacyRoot, withDestinationURL: externalRoot)

    let store = LibraryStore(
      applicationSupportDirectoryOverride: applicationSupportDirectory,
      cachesDirectoryOverride: cachesDirectory)

    XCTAssertEqual(store.rootDirectory.lastPathComponent, AppIdentity.name)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: legacyRoot.path))
    XCTAssertNotNil(store.errorMessage)
  }

  func testExistingCurrentAndLegacyRootsAreNeverMerged() throws {
    let currentRoot = applicationSupportDirectory.appendingPathComponent(
      AppIdentity.name, isDirectory: true)
    let legacyRoot = applicationSupportDirectory.appendingPathComponent(
      AppIdentity.legacyName, isDirectory: true)
    try FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    let currentMarker = currentRoot.appendingPathComponent("current.txt")
    let legacyMarker = legacyRoot.appendingPathComponent("legacy.txt")
    try Data("current".utf8).write(to: currentMarker)
    try Data("legacy".utf8).write(to: legacyMarker)

    let resolution = AppMigration.resolveApplicationSupportRoot(
      fileManager: .default,
      baseDirectory: applicationSupportDirectory)

    XCTAssertEqual(resolution.rootDirectory, currentRoot)
    XCTAssertTrue(FileManager.default.fileExists(atPath: currentMarker.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyMarker.path))
    XCTAssertNotNil(resolution.warning)
  }

  func testEmptyUnmarkedCurrentRootDoesNotHidePopulatedLegacyData() throws {
    let currentRoot = applicationSupportDirectory.appendingPathComponent(
      AppIdentity.name, isDirectory: true)
    let legacyRoot = applicationSupportDirectory.appendingPathComponent(
      AppIdentity.legacyName, isDirectory: true)
    try FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    let legacyPlaylists = legacyRoot.appendingPathComponent("playlists.json")
    try Data("[]".utf8).write(to: legacyPlaylists)

    let resolution = AppMigration.resolveApplicationSupportRoot(
      fileManager: .default,
      baseDirectory: applicationSupportDirectory)

    XCTAssertEqual(resolution.rootDirectory, legacyRoot)
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPlaylists.path))
    XCTAssertNotNil(resolution.warning)
  }

  func testPreferenceMigrationCopiesKnownKeysWithoutOverwritingNewValues() throws {
    let suiteName = "LiltfinchMigrationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("mp3", forKey: "audioFormat")

    AppMigration.migrateLegacyPreferences(
      to: defaults,
      legacyValues: [
        "audioFormat": "best",
        "downloaderPath": "/opt/homebrew/bin/yt-dlp",
        "ffmpegPath": "/opt/homebrew/bin/ffmpeg",
        "autoplayEnabled": false,
        "unrelatedKey": "ignored",
      ])

    XCTAssertEqual(defaults.string(forKey: "audioFormat"), "mp3")
    XCTAssertEqual(defaults.string(forKey: "downloaderPath"), "/opt/homebrew/bin/yt-dlp")
    XCTAssertEqual(defaults.string(forKey: "ffmpegPath"), "/opt/homebrew/bin/ffmpeg")
    XCTAssertEqual(defaults.object(forKey: "autoplayEnabled") as? Bool, false)
    XCTAssertNil(defaults.object(forKey: "unrelatedKey"))
    XCTAssertEqual(defaults.integer(forKey: AppIdentity.preferenceMigrationVersionKey), 1)

    defaults.removeObject(forKey: "downloaderPath")
    AppMigration.migrateLegacyPreferences(
      to: defaults,
      legacyValues: ["downloaderPath": "/changed", "autoplayEnabled": true])
    XCTAssertNil(defaults.object(forKey: "downloaderPath"))
    XCTAssertEqual(defaults.object(forKey: "autoplayEnabled") as? Bool, false)
  }

  private func makeLegacyLibrary() throws -> (store: LibraryStore, item: SearchResult) {
    let legacyRoot = applicationSupportDirectory.appendingPathComponent(
      AppIdentity.legacyName, isDirectory: true)
    let legacyCache = cachesDirectory.appendingPathComponent(
      AppIdentity.legacyName, isDirectory: true)
    let store = LibraryStore(rootOverride: legacyRoot, cacheOverride: legacyCache)
    let item = SearchResult(
      id: "legacy-track",
      title: "Legacy Track",
      artist: "Test Artist",
      duration: 3,
      webpageURLString: "https://www.youtube.com/watch?v=legacy-track",
      thumbnailURLString: nil)
    let jobID = UUID()
    let staging = try store.makeStagingDirectory(jobID: jobID)
    let audio = staging.appendingPathComponent("\(item.id).m4a")
    let artwork = staging.appendingPathComponent("\(item.id).jpg")
    try Data("audio".utf8).write(to: audio)
    try Data("artwork".utf8).write(to: artwork)
    let artifact = DownloadArtifact(
      metadata: item,
      output: DownloadOutput(id: item.id, filepath: audio.path, ext: "m4a"),
      stagingDirectory: staging)
    _ = try store.importArtifact(artifact, intent: .keep, jobID: jobID)
    return (store, item)
  }

  private func decodeTracks(at url: URL) throws -> [Track] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([Track].self, from: Data(contentsOf: url))
  }

  private func encodeTracks(_ tracks: [Track]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(tracks)
  }
}
