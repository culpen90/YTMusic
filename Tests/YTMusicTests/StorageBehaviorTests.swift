import AVFoundation
import XCTest

@testable import YTMusic

@MainActor
final class StorageBehaviorTests: XCTestCase {
  private var testRoot: URL!
  private var cacheRoot: URL!

  override func setUp() {
    super.setUp()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("YTMusicTests-\(UUID().uuidString)", isDirectory: true)
    testRoot = base.appendingPathComponent("Library", isDirectory: true)
    cacheRoot = base.appendingPathComponent("Cache", isDirectory: true)
  }

  override func tearDown() {
    if let testRoot {
      try? FileManager.default.removeItem(at: testRoot.deletingLastPathComponent())
    }
    super.tearDown()
  }

  func testPlayOnceDeletesEntirePerSongFolderAndNeverEntersLibrary() throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let jobID = UUID()
    let staging = try store.makeStagingDirectory(jobID: jobID)
    let audio = staging.appendingPathComponent("temporary-id.opus")
    let artwork = staging.appendingPathComponent("temporary-id.jpg")
    try Data("fake audio".utf8).write(to: audio)
    try Data("fake art".utf8).write(to: artwork)

    let artifact = DownloadArtifact(
      metadata: sampleResult(id: "temporary-id"),
      output: DownloadOutput(id: "temporary-id", filepath: audio.path, ext: "opus"),
      stagingDirectory: staging
    )
    let track = try store.importArtifact(artifact, intent: .playOnce, jobID: jobID)

    XCTAssertEqual(track.storage, .temporary)
    XCTAssertTrue(FileManager.default.fileExists(atPath: track.audioURL.path))
    XCTAssertTrue(store.tracks.isEmpty)
    let songFolder = track.audioURL.deletingLastPathComponent()

    store.deleteTemporaryTrack(track)

    XCTAssertFalse(FileManager.default.fileExists(atPath: songFolder.path))
    XCTAssertTrue(store.tracks.isEmpty)
  }

  func testKeepPersistsAudioAndLibraryMetadata() throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let jobID = UUID()
    let staging = try store.makeStagingDirectory(jobID: jobID)
    let audio = staging.appendingPathComponent("kept-id.m4a")
    try Data("fake audio".utf8).write(to: audio)
    let artifact = DownloadArtifact(
      metadata: sampleResult(id: "kept-id"),
      output: DownloadOutput(id: "kept-id", filepath: audio.path, ext: "m4a"),
      stagingDirectory: staging
    )

    let track = try store.importArtifact(artifact, intent: .keep, jobID: jobID)
    XCTAssertEqual(track.storage, .library)
    XCTAssertTrue(store.contains("kept-id"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: track.audioURL.path))

    let reloaded = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    XCTAssertTrue(reloaded.contains("kept-id"))
  }

  func testPlaylistFileContainsReferencesButNoAudioPaths() throws {
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    let playlists = PlaylistStore(rootDirectory: testRoot)
    let playlistID = try XCTUnwrap(playlists.create(name: "Road Trip"))
    playlists.add(sampleResult(id: "reference-only"), to: playlistID)

    let data = try Data(contentsOf: testRoot.appendingPathComponent("playlists.json"))
    let json = String(decoding: data, as: UTF8.self)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode([Playlist].self, from: data)
    XCTAssertEqual(
      decoded.first?.items.first?.webpageURLString, "https://www.youtube.com/watch?v=reference-only"
    )
    XCTAssertFalse(json.contains("localFilePath"))
    XCTAssertFalse(json.contains(".opus"))
    XCTAssertFalse(json.contains(".m4a"))
  }

  func testNaturalPlaybackEndDeletesTemporarySongFolder() async throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let songFolder = store.temporaryPlaybackDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: songFolder, withIntermediateDirectories: true)
    let audioURL = songFolder.appendingPathComponent("short-tone.wav")
    try Self.writeShortTone(to: audioURL)
    try Data("temporary artwork".utf8).write(
      to: songFolder.appendingPathComponent("short-tone.jpg"))

    let track = Track(
      id: "short-tone",
      title: "Short Tone",
      artist: "Test",
      duration: 0.2,
      sourceURLString: "https://www.youtube.com/watch?v=short-tone",
      thumbnailURLString: nil,
      localFilePath: audioURL.path,
      localArtworkFilePath: songFolder.appendingPathComponent("short-tone.jpg").path,
      storage: .temporary,
      format: "wav",
      fileSize: nil,
      dateAdded: Date(),
      lastPlayedAt: nil,
      playCount: 0
    )
    let deleted = expectation(description: "temporary song folder deleted")
    let player = PlayerStore()
    player.onTemporaryTrackFinished = { temporaryTrack in
      store.deleteTemporaryTrack(temporaryTrack)
      deleted.fulfill()
    }

    player.play(track)
    await fulfillment(of: [deleted], timeout: 4)

    XCTAssertFalse(FileManager.default.fileExists(atPath: songFolder.path))
    player.shutdown()
  }

  func testTamperedLibraryPathCannotDeleteFileOutsideManagedFolder() throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let outsideFile = testRoot.deletingLastPathComponent().appendingPathComponent("important.txt")
    try Data("keep me".utf8).write(to: outsideFile)
    let maliciousTrack = Track(
      id: "tampered",
      title: "Tampered",
      artist: "Unknown",
      duration: 1,
      sourceURLString: "https://www.youtube.com/watch?v=tampered",
      thumbnailURLString: nil,
      localFilePath: outsideFile.path,
      localArtworkFilePath: nil,
      storage: .library,
      format: "txt",
      fileSize: nil,
      dateAdded: Date(),
      lastPlayedAt: nil,
      playCount: 0
    )

    store.deleteFromLibrary(maliciousTrack)

    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    XCTAssertNotNil(store.errorMessage)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([maliciousTrack]).write(
      to: testRoot.appendingPathComponent("library.json"), options: .atomic)
    let reloaded = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    XCTAssertTrue(reloaded.tracks.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
  }

  func testSymlinkInsideLibraryCannotEscapeDeletionBoundary() throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let outsideFile = testRoot.deletingLastPathComponent().appendingPathComponent(
      "outside-audio.opus")
    try Data("keep me too".utf8).write(to: outsideFile)
    let symlink = store.mediaDirectory.appendingPathComponent("linked.opus")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideFile)
    var linkedTrack = sampleTrack(id: "linked", path: symlink.path)
    linkedTrack.storage = .library

    store.deleteFromLibrary(linkedTrack)

    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
  }

  func testStagedSymlinkCannotBeImported() throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let jobID = UUID()
    let staging = try store.makeStagingDirectory(jobID: jobID)
    let outsideFile = testRoot.deletingLastPathComponent().appendingPathComponent("outside.opus")
    try Data("outside audio".utf8).write(to: outsideFile)
    let linkedAudio = staging.appendingPathComponent("linked-id.opus")
    try FileManager.default.createSymbolicLink(at: linkedAudio, withDestinationURL: outsideFile)
    let artifact = DownloadArtifact(
      metadata: sampleResult(id: "linked-id"),
      output: DownloadOutput(id: "linked-id", filepath: linkedAudio.path, ext: "opus"),
      stagingDirectory: staging
    )

    XCTAssertThrowsError(try store.importArtifact(artifact, intent: .keep, jobID: jobID))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    XCTAssertTrue(store.tracks.isEmpty)
  }

  func testSymlinkedCacheRootCannotRedirectCleanup() throws {
    let base = testRoot.deletingLastPathComponent()
    let externalCache = base.appendingPathComponent("ExternalCache", isDirectory: true)
    let externalStaging = externalCache.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: externalStaging, withIntermediateDirectories: true)
    let marker = externalStaging.appendingPathComponent("do-not-delete.txt")
    try Data("keep".utf8).write(to: marker)
    let linkedCache = base.appendingPathComponent("LinkedCache", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedCache, withDestinationURL: externalCache)

    let store = LibraryStore(rootOverride: testRoot, cacheOverride: linkedCache)

    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertNotNil(store.errorMessage)
  }

  func testCorruptPlaylistMetadataIsNeverOverwrittenByMutation() throws {
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    let metadataURL = testRoot.appendingPathComponent("playlists.json")
    let corruptData = Data("not valid json".utf8)
    try corruptData.write(to: metadataURL)

    let store = PlaylistStore(rootDirectory: testRoot)
    XCTAssertNil(store.create(name: "Must Not Replace Corrupt Data"))
    XCTAssertEqual(try Data(contentsOf: metadataURL), corruptData)
    XCTAssertNotNil(store.errorMessage)
  }

  func testCorruptLibraryMetadataBlocksImportAndRollsBackMedia() throws {
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    let metadataURL = testRoot.appendingPathComponent("library.json")
    let corruptData = Data("not valid json".utf8)
    try corruptData.write(to: metadataURL)
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let jobID = UUID()
    let staging = try store.makeStagingDirectory(jobID: jobID)
    let audio = staging.appendingPathComponent("blocked-id.opus")
    try Data("audio".utf8).write(to: audio)
    let artifact = DownloadArtifact(
      metadata: sampleResult(id: "blocked-id"),
      output: DownloadOutput(id: "blocked-id", filepath: audio.path, ext: "opus"),
      stagingDirectory: staging
    )

    XCTAssertThrowsError(try store.importArtifact(artifact, intent: .keep, jobID: jobID))
    XCTAssertEqual(try Data(contentsOf: metadataURL), corruptData)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path).isEmpty)
  }

  func testLibrarySaveFailureRollsBackImportedMedia() throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    try FileManager.default.createDirectory(
      at: testRoot.appendingPathComponent("library.json", isDirectory: true),
      withIntermediateDirectories: false
    )
    let jobID = UUID()
    let staging = try store.makeStagingDirectory(jobID: jobID)
    let audio = staging.appendingPathComponent("rollback-id.opus")
    try Data("audio".utf8).write(to: audio)
    let artifact = DownloadArtifact(
      metadata: sampleResult(id: "rollback-id"),
      output: DownloadOutput(id: "rollback-id", filepath: audio.path, ext: "opus"),
      stagingDirectory: staging
    )

    XCTAssertThrowsError(try store.importArtifact(artifact, intent: .keep, jobID: jobID))
    XCTAssertTrue(store.tracks.isEmpty)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path).isEmpty)
  }

  func testPlaylistSaveFailureRollsBackInMemoryMutation() throws {
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    let store = PlaylistStore(rootDirectory: testRoot)
    try FileManager.default.createDirectory(
      at: testRoot.appendingPathComponent("playlists.json", isDirectory: true),
      withIntermediateDirectories: false
    )

    XCTAssertNil(store.create(name: "Cannot Persist"))
    XCTAssertTrue(store.playlists.isEmpty)
    XCTAssertNotNil(store.errorMessage)
  }

  func testSymlinkedLibraryRootCannotOverwriteTargetMetadata() throws {
    let base = testRoot.deletingLastPathComponent()
    let externalRoot = base.appendingPathComponent("ExternalLibrary", isDirectory: true)
    let externalMedia = externalRoot.appendingPathComponent("Media", isDirectory: true)
    try FileManager.default.createDirectory(at: externalMedia, withIntermediateDirectories: true)
    let audio = externalMedia.appendingPathComponent("existing.opus")
    try Data("audio".utf8).write(to: audio)
    var existing = sampleTrack(id: "existing", path: audio.path)
    existing.storage = .library
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let originalData = try encoder.encode([existing])
    let libraryMetadata = externalRoot.appendingPathComponent("library.json")
    try originalData.write(to: libraryMetadata)
    let playlistMetadata = externalRoot.appendingPathComponent("playlists.json")
    let playlistData = Data("[]".utf8)
    try playlistData.write(to: playlistMetadata)

    let linkedRoot = base.appendingPathComponent("LinkedLibrary", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: externalRoot)
    let library = LibraryStore(rootOverride: linkedRoot, cacheOverride: cacheRoot)
    let playlists = PlaylistStore(rootDirectory: linkedRoot)

    XCTAssertTrue(library.tracks.isEmpty)
    XCTAssertNil(playlists.create(name: "Must Not Write"))
    XCTAssertEqual(try Data(contentsOf: libraryMetadata), originalData)
    XCTAssertEqual(try Data(contentsOf: playlistMetadata), playlistData)
    XCTAssertNotNil(library.errorMessage)
    XCTAssertNotNil(playlists.errorMessage)
  }

  func testMissingPrimaryLibraryMetadataRecoversFromBackup() throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let jobID = UUID()
    let staging = try store.makeStagingDirectory(jobID: jobID)
    let audio = staging.appendingPathComponent("backup-id.opus")
    try Data("audio".utf8).write(to: audio)
    let artifact = DownloadArtifact(
      metadata: sampleResult(id: "backup-id"),
      output: DownloadOutput(id: "backup-id", filepath: audio.path, ext: "opus"),
      stagingDirectory: staging
    )
    _ = try store.importArtifact(artifact, intent: .keep, jobID: jobID)
    let metadata = testRoot.appendingPathComponent("library.json")
    let backup = testRoot.appendingPathComponent("library.backup.json")
    let backupData = try Data(contentsOf: backup)
    try FileManager.default.removeItem(at: metadata)

    let recovered = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)

    XCTAssertTrue(recovered.contains("backup-id"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    XCTAssertEqual(try Data(contentsOf: backup), backupData)
  }

  func testMissingPrimaryPlaylistMetadataRecoversFromBackup() throws {
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    let store = PlaylistStore(rootDirectory: testRoot)
    let playlistID = try XCTUnwrap(store.create(name: "Backup List"))
    store.add(sampleResult(id: "reference"), to: playlistID)
    let metadata = testRoot.appendingPathComponent("playlists.json")
    let backup = testRoot.appendingPathComponent("playlists.backup.json")
    let backupData = try Data(contentsOf: backup)
    try FileManager.default.removeItem(at: metadata)

    let recovered = PlaylistStore(rootDirectory: testRoot)

    XCTAssertEqual(recovered.playlist(id: playlistID)?.items.first?.id, "reference")
    XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    XCTAssertEqual(try Data(contentsOf: backup), backupData)
  }

  func testDeleteUsesAuthoritativeStoredPathInsteadOfCallerPath() throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let jobID = UUID()
    let staging = try store.makeStagingDirectory(jobID: jobID)
    let audio = staging.appendingPathComponent("authoritative.opus")
    try Data("audio".utf8).write(to: audio)
    let artifact = DownloadArtifact(
      metadata: sampleResult(id: "authoritative"),
      output: DownloadOutput(id: "authoritative", filepath: audio.path, ext: "opus"),
      stagingDirectory: staging
    )
    let stored = try store.importArtifact(artifact, intent: .keep, jobID: jobID)
    let unrelated = store.mediaDirectory.appendingPathComponent("unrelated.opus")
    try Data("do not trash".utf8).write(to: unrelated)
    var callerTrack = stored
    callerTrack.localFilePath = unrelated.path

    store.deleteFromLibrary(callerTrack)

    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: stored.audioURL.path))
    XCTAssertFalse(store.contains(stored.id))
  }

  func testDuplicatePersistedTrackRecordsAreCollapsed() throws {
    let store = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let audio = store.mediaDirectory.appendingPathComponent("duplicate.opus")
    try Data("audio".utf8).write(to: audio)
    var track = sampleTrack(id: "duplicate", path: audio.path)
    track.storage = .library
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([track, track]).write(
      to: testRoot.appendingPathComponent("library.json"), options: .atomic)

    let reloaded = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)

    XCTAssertEqual(reloaded.tracks.count, 1)
    XCTAssertEqual(reloaded.tracks.first?.id, "duplicate")
  }

  func testOrphanedMediaFromInterruptedImportIsReconciledOnLaunch() throws {
    let initial = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)
    let orphan = initial.mediaDirectory.appendingPathComponent("interrupted.opus")
    let orphanArtwork = initial.artworkDirectory.appendingPathComponent("interrupted.jpg")
    try Data("orphan audio".utf8).write(to: orphan)
    try Data("orphan artwork".utf8).write(to: orphanArtwork)

    let reloaded = LibraryStore(rootOverride: testRoot, cacheOverride: cacheRoot)

    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanArtwork.path))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: reloaded.recoveryDirectory.path).count, 2)
    XCTAssertNotNil(reloaded.errorMessage)
  }

  private func sampleResult(id: String) -> SearchResult {
    SearchResult(
      id: id,
      title: "Test Tone",
      artist: "Public Domain",
      duration: 3,
      webpageURLString: "https://www.youtube.com/watch?v=\(id)",
      thumbnailURLString: nil
    )
  }

  private func sampleTrack(id: String, path: String) -> Track {
    Track(
      id: id,
      title: "Test Tone",
      artist: "Public Domain",
      duration: 3,
      sourceURLString: "https://www.youtube.com/watch?v=\(id)",
      thumbnailURLString: nil,
      localFilePath: path,
      localArtworkFilePath: nil,
      storage: .temporary,
      format: "opus",
      fileSize: nil,
      dateAdded: Date(),
      lastPlayedAt: nil,
      playCount: 0
    )
  }

  private static func writeShortTone(to url: URL) throws {
    let sampleRate = 44_100.0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(sampleRate * 0.2)
      ),
      let samples = buffer.floatChannelData?[0]
    else {
      throw NSError(domain: "YTMusicTests", code: 1)
    }
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
      samples[frame] = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate) * 0.1)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }
}
