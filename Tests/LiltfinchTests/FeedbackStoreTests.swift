import XCTest

@testable import Liltfinch

@MainActor
final class FeedbackStoreTests: XCTestCase {
  private var baseDirectory: URL!
  private var rootDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    baseDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiltfinchFeedbackTests-\(UUID().uuidString)", isDirectory: true)
    rootDirectory = baseDirectory.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let baseDirectory {
      try? FileManager.default.removeItem(at: baseDirectory)
    }
    try super.tearDownWithError()
  }

  func testRatingPersistsSongMetadataAcrossReload() throws {
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let item = song(id: "liked-song", artist: "Example Artist")
    let store = FeedbackStore(rootDirectory: rootDirectory, now: { fixedDate })

    store.setRating(.liked, for: item)

    XCTAssertEqual(store.rating(for: item.id), .liked)
    let reloaded = FeedbackStore(rootDirectory: rootDirectory)
    XCTAssertEqual(reloaded.rating(for: item), .liked)
    XCTAssertEqual(reloaded.records.first?.item, item)
    XCTAssertEqual(reloaded.records.first?.updatedAt, fixedDate)
  }

  func testChangingAndClearingRatingKeepsOneMutuallyExclusiveRecord() {
    let item = song(id: "changed-song", artist: "Example Artist")
    let store = FeedbackStore(rootDirectory: rootDirectory)

    store.setRating(.liked, for: item)
    store.setRating(.disliked, for: item)

    XCTAssertEqual(store.rating(for: item.id), .disliked)
    XCTAssertEqual(store.records.count, 1)

    store.setRating(nil, for: item)

    XCTAssertNil(store.rating(for: item.id))
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertNil(FeedbackStore(rootDirectory: rootDirectory).rating(for: item.id))
  }

  func testFavoritesContainOnlyCurrentThumbsUpsAcrossReload() {
    var timestamp = 1_700_000_000.0
    let store = FeedbackStore(rootDirectory: rootDirectory) {
      defer { timestamp += 1 }
      return Date(timeIntervalSince1970: timestamp)
    }
    let first = song(id: "favorite-first", artist: "First Artist")
    let second = song(id: "favorite-second", artist: "Second Artist")
    let disliked = song(id: "disliked-song", artist: "Other Artist")

    store.setRating(.liked, for: first)
    store.setRating(.liked, for: second)
    store.setRating(.liked, for: second)
    store.setRating(.disliked, for: disliked)

    XCTAssertEqual(store.favoriteItems, [second, first])
    XCTAssertEqual(store.records.filter { $0.id == second.id }.count, 1)

    let reloaded = FeedbackStore(rootDirectory: rootDirectory)
    XCTAssertEqual(reloaded.favoriteItems, [second, first])

    reloaded.setRating(.disliked, for: second)
    XCTAssertEqual(reloaded.favoriteItems, [first])

    reloaded.setRating(nil, for: first)
    XCTAssertTrue(reloaded.favoriteItems.isEmpty)
    XCTAssertTrue(FeedbackStore(rootDirectory: rootDirectory).favoriteItems.isEmpty)
  }

  func testRepeatedThumbsUpKeepsOneFavorite() {
    let item = song(id: "toggle-favorite", artist: "Example Artist")
    let store = FeedbackStore(rootDirectory: rootDirectory)

    store.setRating(.liked, for: item)
    store.setRating(.liked, for: item)

    XCTAssertEqual(store.rating(for: item), .liked)
    XCTAssertEqual(store.favoriteItems, [item])
    XCTAssertEqual(store.records.count, 1)
    XCTAssertEqual(FeedbackStore(rootDirectory: rootDirectory).favoriteItems, [item])
  }

  func testReloadedLikeStillInfluencesRecommendationRanking() {
    let store = FeedbackStore(rootDirectory: rootDirectory)
    store.setRating(.liked, for: song(id: "liked-source", artist: "Favorite Artist"))

    let reloaded = FeedbackStore(rootDirectory: rootDirectory)
    let ranked = reloaded.rankedRecommendations(from: [
      song(id: "neutral", artist: "Neutral Artist"),
      song(id: "favorite", artist: "favorite artist - Topic"),
    ])

    XCTAssertEqual(ranked.map(\.id), ["favorite", "neutral"])
  }

  func testRankingAppliesFeedbackExclusionsAndStableSourceOrder() {
    let store = FeedbackStore(rootDirectory: rootDirectory)
    store.setRating(.liked, for: song(id: "liked-source", artist: "Beyoncé - Topic"))
    store.setRating(.disliked, for: song(id: "blocked", artist: "Noise Artist - Topic"))

    let neutralFirst = song(id: "neutral-1", artist: "Neutral One")
    let neutralSecond = song(id: "neutral-2", artist: "Neutral Two")
    let candidates = [
      song(id: "current", artist: "Current Artist"),
      song(id: "blocked", artist: "Noise Artist"),
      song(id: "seen", artist: "Seen Artist"),
      neutralFirst,
      song(id: "demoted", artist: "noise artist"),
      song(id: "favored", artist: " beyonce "),
      neutralSecond,
      song(id: "neutral-1", artist: "Duplicate", title: "Later duplicate"),
    ]

    let ranked = store.rankedRecommendations(
      from: candidates,
      excluding: ["current", "seen"])

    XCTAssertEqual(ranked.map(\.id), ["favored", "neutral-1", "neutral-2", "demoted"])
    XCTAssertEqual(ranked.first(where: { $0.id == "neutral-1" }), neutralFirst)
  }

  func testClearingDislikeRestoresCandidateEligibility() {
    let item = song(id: "restored", artist: "Example Artist")
    let store = FeedbackStore(rootDirectory: rootDirectory)
    store.setRating(.disliked, for: item)

    XCTAssertTrue(store.rankedRecommendations(from: [item], excluding: []).isEmpty)

    store.setRating(nil, for: item)

    XCTAssertEqual(store.rankedRecommendations(from: [item], excluding: []), [item])
  }

  func testPersistedJSONContainsNoPlaybackOrLocalFileState() throws {
    let item = song(id: "metadata-only", artist: "Example Artist")
    let store = FeedbackStore(rootDirectory: rootDirectory)
    store.setRating(.liked, for: item)

    let data = try Data(contentsOf: rootDirectory.appendingPathComponent("feedback.json"))
    let json = String(decoding: data, as: UTF8.self)

    XCTAssertTrue(json.contains("metadata-only"))
    XCTAssertTrue(json.contains("webpage_url"))
    XCTAssertFalse(json.contains("googlevideo"))
    XCTAssertFalse(json.contains("audioURL"))
    XCTAssertFalse(json.contains("localFilePath"))
    XCTAssertFalse(json.contains("resolvedStream"))
  }

  func testCorruptPrimaryRecoversFromBackupAndPreservesRating() throws {
    let item = song(id: "recoverable", artist: "Example Artist")
    let store = FeedbackStore(rootDirectory: rootDirectory)
    store.setRating(.liked, for: item)
    let metadataURL = rootDirectory.appendingPathComponent("feedback.json")
    try Data("not valid json".utf8).write(to: metadataURL)

    let recovered = FeedbackStore(rootDirectory: rootDirectory)

    XCTAssertEqual(recovered.rating(for: item.id), .liked)
    XCTAssertNotNil(recovered.errorMessage)
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)
      .filter { $0.hasPrefix("feedback.corrupt.") }
    XCTAssertEqual(quarantined.count, 1)
  }

  func testUnrecoverableCorruptPrimaryIsPreservedAndBlocksMutation() throws {
    let metadataURL = rootDirectory.appendingPathComponent("feedback.json")
    let corruptData = Data("not valid json".utf8)
    try corruptData.write(to: metadataURL)
    let store = FeedbackStore(rootDirectory: rootDirectory)

    store.setRating(.liked, for: song(id: "must-not-save", artist: "Example Artist"))

    XCTAssertEqual(try Data(contentsOf: metadataURL), corruptData)
    XCTAssertTrue(store.records.isEmpty)
    XCTAssertNotNil(store.errorMessage)
  }

  func testSymlinkedRootCannotWriteIntoExternalDirectory() throws {
    try FileManager.default.removeItem(at: rootDirectory)
    let externalRoot = baseDirectory.appendingPathComponent("External", isDirectory: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    let markerURL = externalRoot.appendingPathComponent("marker.txt")
    try Data("keep".utf8).write(to: markerURL)
    try FileManager.default.createSymbolicLink(at: rootDirectory, withDestinationURL: externalRoot)

    let store = FeedbackStore(rootDirectory: rootDirectory)
    store.setRating(.liked, for: song(id: "must-not-write", artist: "Example Artist"))

    XCTAssertEqual(try Data(contentsOf: markerURL), Data("keep".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: externalRoot.appendingPathComponent("feedback.json").path))
    XCTAssertNotNil(store.errorMessage)
  }

  private func song(
    id: String,
    artist: String,
    title: String = "Test Song"
  ) -> SearchResult {
    SearchResult(
      id: id,
      title: title,
      artist: artist,
      duration: 180,
      webpageURLString: "https://www.youtube.com/watch?v=\(id)",
      thumbnailURLString: "https://images.example.test/\(id).jpg"
    )
  }
}
