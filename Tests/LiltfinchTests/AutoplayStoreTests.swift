import XCTest

@testable import Liltfinch

@MainActor
final class AutoplayStoreTests: XCTestCase {
  private typealias RecommendationGate = ControlledOperation<SearchResult, [SearchResult]>
  private typealias StreamGate = ControlledOperation<SearchResult, PlaybackStream>

  private let preparedAt = Date(timeIntervalSince1970: 1_700_000_000)
  private var baseDirectory: URL!
  private var rootDirectory: URL!
  private var cacheDirectory: URL!
  private var defaults: UserDefaults!
  private var defaultsSuiteName: String!

  override func setUpWithError() throws {
    try super.setUpWithError()
    baseDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiltfinchAutoplayTests-\(UUID().uuidString)", isDirectory: true)
    rootDirectory = baseDirectory.appendingPathComponent("Library", isDirectory: true)
    cacheDirectory = baseDirectory.appendingPathComponent("Cache", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

    defaultsSuiteName = "LiltfinchAutoplayTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
    defaults.removePersistentDomain(forName: defaultsSuiteName)
  }

  override func tearDownWithError() throws {
    if let defaults, let defaultsSuiteName {
      defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
    if let baseDirectory {
      try? FileManager.default.removeItem(at: baseDirectory)
    }
    try super.tearDownWithError()
  }

  func testPreparationBecomesReadyAfterRecommendationAndStreamResolution() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed")
    let candidate = song(id: "candidate")
    let resolvedStream = stream(id: candidate.id)
    let finished = expectation(description: "preparation finished")
    harness.store.onPreparationFinished = { finished.fulfill() }

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())

    let recommendationRequest = await recommendations.nextRequest()
    XCTAssertEqual(recommendationRequest.input, seed)
    XCTAssertTrue(harness.store.isPreparing)
    XCTAssertNil(harness.store.nextItem)
    XCTAssertNil(harness.store.preparedPlayback)

    await recommendations.succeed(recommendationRequest, with: [candidate])
    let streamRequest = await streams.nextRequest()
    XCTAssertEqual(streamRequest.input, candidate)
    XCTAssertEqual(harness.store.nextItem, candidate)
    XCTAssertTrue(harness.store.isPreparing)
    XCTAssertNil(harness.store.preparedPlayback)

    await streams.succeed(streamRequest, with: resolvedStream)
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertFalse(harness.store.isPreparing)
    XCTAssertEqual(harness.store.preparedPlayback?.item, candidate)
    XCTAssertEqual(harness.store.preparedPlayback?.resolvedStream, resolvedStream)
    XCTAssertEqual(harness.store.preparedPlayback?.preparedAt, preparedAt)
    XCTAssertNil(harness.store.errorMessage)
    await harness.store.shutdown()
  }

  func testPreparationSkipsPlayedTrackAndEquivalentUpload() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed")
    let played = song(id: "played", artist: "Example Artist", title: "Already Heard")
    let equivalentUpload = song(
      id: "alternate-upload",
      artist: " example artist - Topic ",
      title: "  ALREADY   HEARD ")
    let fresh = song(id: "fresh", title: "Something New")
    let finished = expectation(description: "fresh recommendation prepared")
    harness.store.onPreparationFinished = { finished.fulfill() }
    harness.store.recordPlayback(of: played)

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      toolchain: ToolchainStatus())
    let recommendationRequest = await recommendations.nextRequest()
    await recommendations.succeed(
      recommendationRequest,
      with: [played, equivalentUpload, fresh])

    let streamRequest = await streams.nextRequest()
    XCTAssertEqual(streamRequest.input, fresh)
    await streams.succeed(streamRequest, with: stream(id: fresh.id))
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertEqual(harness.store.preparedPlayback?.item, fresh)
    let streamCallCount = await streams.callCount()
    XCTAssertEqual(streamCallCount, 1)
    await harness.store.shutdown()
  }

  func testPreparationStopsWhenEveryRecommendationWasPlayed() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed")
    let played = song(id: "played")
    let equivalentUpload = song(id: "alternate", title: played.title)
    let finished = expectation(description: "preparation finished without a repeat")
    harness.store.onPreparationFinished = { finished.fulfill() }
    harness.store.recordPlayback(of: played)

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      toolchain: ToolchainStatus())
    let recommendationRequest = await recommendations.nextRequest()
    await recommendations.succeed(recommendationRequest, with: [played, equivalentUpload])
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertNil(harness.store.nextItem)
    XCTAssertNil(harness.store.preparedPlayback)
    XCTAssertEqual(
      harness.store.errorMessage,
      AutoplayPreparationError.noRecommendation.localizedDescription)
    let streamCallCount = await streams.callCount()
    XCTAssertEqual(streamCallCount, 0)
    await harness.store.shutdown()
  }

  func testPlaybackHistoryDoesNotEvictOlderTracks() {
    var history = AutoplayHistory()
    let tracks = (0..<75).map { song(id: "song-\($0)") }

    for track in tracks {
      history.record(track)
    }

    XCTAssertEqual(history.playedIDs.count, tracks.count)
    XCTAssertTrue(history.contains(tracks[0]))
    XCTAssertTrue(history.contains(tracks[50]))
    XCTAssertTrue(history.contains(tracks[74]))
  }

  func testPlaybackHistoryKeepsDistinctSongVersionsEligible() {
    var history = AutoplayHistory()
    history.record(song(id: "studio", title: "Example Song", duration: 180))

    XCTAssertFalse(
      history.contains(song(id: "live", title: "Example Song (Live)", duration: 240)))
    XCTAssertFalse(
      history.contains(song(id: "remaster", title: "Example Song (2026 Remaster)", duration: 185)))
    XCTAssertFalse(
      history.contains(song(id: "extended", title: "Example Song", duration: 240)))
  }

  func testPlaybackHistoryMatchesCommonYouTubePresentationLabels() {
    var history = AutoplayHistory()
    history.record(
      song(id: "audio", artist: "Example Artist - Topic", title: "Example Song", duration: 180))

    XCTAssertTrue(
      history.contains(
        song(
          id: "video",
          artist: "Example ArtistVEVO",
          title: "Example Song (Official Music Video)",
          duration: 205)))
  }

  func testPreparedPlaybackCanOnlyBeConsumedOnce() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed")
    let candidate = song(id: "candidate")
    let finished = expectation(description: "preparation finished")
    harness.store.onPreparationFinished = { finished.fulfill() }

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())
    let recommendationRequest = await recommendations.nextRequest()
    await recommendations.succeed(recommendationRequest, with: [candidate])
    let streamRequest = await streams.nextRequest()
    await streams.succeed(streamRequest, with: stream(id: candidate.id))
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertNil(harness.store.consumePrepared(matching: "different-item"))
    XCTAssertNotNil(harness.store.preparedPlayback)

    let consumed = try XCTUnwrap(harness.store.consumePrepared(matching: candidate.id))
    XCTAssertEqual(consumed.item, candidate)
    XCTAssertNil(harness.store.consumePrepared())
    XCTAssertNil(harness.store.preparedPlayback)
    XCTAssertNil(harness.store.nextItem)
    await harness.store.shutdown()
  }

  func testQueuedPlaylistItemBypassesRecommendationsWhenAutoplayIsDisabled() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "playlist-current")
    let queued = song(id: "playlist-next")
    let finished = expectation(description: "queued item prepared")
    harness.store.onPreparationFinished = { finished.fulfill() }
    harness.store.setEnabled(false)
    harness.store.recordPlayback(of: queued)

    harness.store.prepareNext(
      after: seed,
      queuedNext: queued,
      excluding: [],
      toolchain: ToolchainStatus())

    let streamRequest = await streams.nextRequest()
    XCTAssertEqual(streamRequest.input, queued)
    let recommendationCallCount = await recommendations.callCount()
    XCTAssertEqual(recommendationCallCount, 0)
    XCTAssertEqual(harness.store.nextItem, queued)

    await streams.succeed(streamRequest, with: stream(id: queued.id))
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertFalse(harness.store.isEnabled)
    XCTAssertEqual(harness.store.preparedPlayback?.item, queued)
    await harness.store.shutdown()
  }

  func testForegroundBarrierDelaysRecommendationUntilItCompletes() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let barrier = ControlledOperation<Void, Void>()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed")
    let candidate = song(id: "candidate")
    let finished = expectation(description: "preparation finished after barrier")
    harness.store.onPreparationFinished = { finished.fulfill() }
    let barrierTask = Task<Void, Never> {
      do {
        try await barrier.call(())
      } catch {
        XCTFail("Foreground barrier unexpectedly failed: \(error)")
      }
    }
    let barrierRequest = await barrier.nextRequest()

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus(),
      waitingFor: barrierTask)
    await Task.yield()

    let callsWhileBlocked = await recommendations.callCount()
    XCTAssertEqual(callsWhileBlocked, 0)
    XCTAssertTrue(harness.store.isPreparing)
    XCTAssertNil(harness.store.nextItem)
    XCTAssertNil(harness.store.preparedPlayback)

    await barrier.succeed(barrierRequest, with: ())
    await barrierTask.value
    let recommendationRequest = await recommendations.nextRequest()
    XCTAssertEqual(recommendationRequest.input, seed)
    await recommendations.succeed(recommendationRequest, with: [candidate])
    let streamRequest = await streams.nextRequest()
    await streams.succeed(streamRequest, with: stream(id: candidate.id))
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertEqual(harness.store.preparedPlayback?.item, candidate)
    XCTAssertFalse(harness.store.isPreparing)
    await harness.store.shutdown()
  }

  func testRatingChangeClearsPreparedResultAndRepreparesWithUpdatedRanking() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed", artist: "Favorite Artist")
    let neutral = song(id: "neutral", artist: "Neutral Artist")
    let matchingArtist = song(id: "matching", artist: "favorite artist - Topic")
    let firstFinished = expectation(description: "initial preparation finished")
    harness.store.onPreparationFinished = { firstFinished.fulfill() }

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())
    let firstRecommendationRequest = await recommendations.nextRequest()
    await recommendations.succeed(firstRecommendationRequest, with: [neutral, matchingArtist])
    let firstStreamRequest = await streams.nextRequest()
    XCTAssertEqual(firstStreamRequest.input, neutral)
    await streams.succeed(firstStreamRequest, with: stream(id: neutral.id))
    await fulfillment(of: [firstFinished], timeout: 2)
    XCTAssertEqual(harness.store.preparedPlayback?.item, neutral)

    harness.feedback.setRating(.liked, for: seed)
    let secondFinished = expectation(description: "updated preparation finished")
    harness.store.onPreparationFinished = { secondFinished.fulfill() }
    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())

    XCTAssertNil(harness.store.preparedPlayback)
    XCTAssertTrue(harness.store.isPreparing)
    let secondRecommendationRequest = await recommendations.nextRequest()
    await recommendations.succeed(secondRecommendationRequest, with: [neutral, matchingArtist])
    let secondStreamRequest = await streams.nextRequest()
    XCTAssertEqual(secondStreamRequest.input, matchingArtist)
    await streams.succeed(secondStreamRequest, with: stream(id: matchingArtist.id))
    await fulfillment(of: [secondFinished], timeout: 2)

    XCTAssertEqual(harness.store.preparedPlayback?.item, matchingArtist)
    XCTAssertNil(harness.store.errorMessage)
    await harness.store.shutdown()
  }

  func testLateCanceledResolutionCannotOverwriteNewGeneration() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let firstSeed = song(id: "first-seed")
    let firstCandidate = song(id: "first-candidate")
    let secondSeed = song(id: "second-seed")
    let secondCandidate = song(id: "second-candidate")
    let finished = expectation(description: "new generation finished")
    harness.store.onPreparationFinished = { finished.fulfill() }

    harness.store.prepareNext(
      after: firstSeed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())
    let firstRecommendationRequest = await recommendations.nextRequest()
    await recommendations.succeed(firstRecommendationRequest, with: [firstCandidate])
    let staleStreamRequest = await streams.nextRequest()
    XCTAssertEqual(staleStreamRequest.input, firstCandidate)

    harness.store.prepareNext(
      after: secondSeed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())
    XCTAssertNil(harness.store.preparedPlayback)
    XCTAssertNil(harness.store.nextItem)
    XCTAssertTrue(harness.store.isPreparing)

    await streams.succeed(staleStreamRequest, with: stream(id: firstCandidate.id))
    let secondRecommendationRequest = await recommendations.nextRequest()
    XCTAssertEqual(secondRecommendationRequest.input, secondSeed)
    XCTAssertNil(harness.store.preparedPlayback)
    XCTAssertNil(harness.store.nextItem)

    await recommendations.succeed(secondRecommendationRequest, with: [secondCandidate])
    let secondStreamRequest = await streams.nextRequest()
    XCTAssertEqual(secondStreamRequest.input, secondCandidate)
    await streams.succeed(secondStreamRequest, with: stream(id: secondCandidate.id))
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertEqual(harness.store.preparedPlayback?.item, secondCandidate)
    XCTAssertNotEqual(harness.store.preparedPlayback?.item.id, firstCandidate.id)
    await harness.store.shutdown()
  }

  func testResolverFailureFallsThroughToNextRankedCandidate() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed")
    let firstCandidate = song(id: "candidate-a")
    let secondCandidate = song(id: "candidate-b")
    let secondStream = stream(id: secondCandidate.id)
    let finished = expectation(description: "fallback candidate prepared")
    harness.store.onPreparationFinished = { finished.fulfill() }

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())
    let recommendationRequest = await recommendations.nextRequest()
    await recommendations.succeed(
      recommendationRequest,
      with: [firstCandidate, secondCandidate])

    let firstStreamRequest = await streams.nextRequest()
    XCTAssertEqual(firstStreamRequest.input, firstCandidate)
    await streams.fail(firstStreamRequest, with: .expected)

    let secondStreamRequest = await streams.nextRequest()
    XCTAssertEqual(secondStreamRequest.input, secondCandidate)
    XCTAssertEqual(harness.store.nextItem, secondCandidate)
    XCTAssertTrue(harness.store.isPreparing)
    XCTAssertNil(harness.store.preparedPlayback)
    await streams.succeed(secondStreamRequest, with: secondStream)
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertEqual(harness.store.preparedPlayback?.item, secondCandidate)
    XCTAssertEqual(harness.store.preparedPlayback?.resolvedStream, secondStream)
    XCTAssertNil(harness.store.errorMessage)
    let recommendationCallCount = await recommendations.callCount()
    let streamCallCount = await streams.callCount()
    XCTAssertEqual(recommendationCallCount, 1)
    XCTAssertEqual(streamCallCount, 2)
    await harness.store.shutdown()
  }

  func testResolutionFailureLeavesNoPreparedState() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed")
    let candidate = song(id: "candidate")
    let finished = expectation(description: "failed preparation finished")
    harness.store.onPreparationFinished = { finished.fulfill() }

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())
    let recommendationRequest = await recommendations.nextRequest()
    await recommendations.succeed(recommendationRequest, with: [candidate])
    let streamRequest = await streams.nextRequest()
    await streams.fail(streamRequest, with: .expected)
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertFalse(harness.store.isPreparing)
    XCTAssertNil(harness.store.nextItem)
    XCTAssertNil(harness.store.preparedPlayback)
    XCTAssertEqual(harness.store.errorMessage, TestFailure.expected.localizedDescription)
    await harness.store.shutdown()
  }

  func testCancelClearsInFlightStateAndIgnoresLateResult() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed")
    var finishCount = 0
    harness.store.onPreparationFinished = { finishCount += 1 }

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())
    let recommendationRequest = await recommendations.nextRequest()
    let canceledTask = harness.store.cancelPreparation()

    XCTAssertFalse(harness.store.isPreparing)
    XCTAssertNil(harness.store.nextItem)
    XCTAssertNil(harness.store.preparedPlayback)
    XCTAssertNil(harness.store.errorMessage)

    await recommendations.succeed(recommendationRequest, with: [song(id: "late")])
    if let canceledTask { await canceledTask.value }

    XCTAssertEqual(finishCount, 0)
    XCTAssertNil(harness.store.preparedPlayback)
    let streamCallCount = await streams.callCount()
    XCTAssertEqual(streamCallCount, 0)
    await harness.store.shutdown()
  }

  func testShutdownClearsPreparedState() async throws {
    let recommendations = RecommendationGate()
    let streams = StreamGate()
    let harness = makeHarness(recommendations: recommendations, streams: streams)
    let seed = song(id: "seed")
    let candidate = song(id: "candidate")
    let finished = expectation(description: "preparation finished")
    harness.store.onPreparationFinished = { finished.fulfill() }

    harness.store.prepareNext(
      after: seed,
      queuedNext: nil,
      excluding: [],
      toolchain: ToolchainStatus())
    let recommendationRequest = await recommendations.nextRequest()
    await recommendations.succeed(recommendationRequest, with: [candidate])
    let streamRequest = await streams.nextRequest()
    await streams.succeed(streamRequest, with: stream(id: candidate.id))
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertNotNil(harness.store.preparedPlayback)

    await harness.store.shutdown()

    XCTAssertFalse(harness.store.isPreparing)
    XCTAssertNil(harness.store.nextItem)
    XCTAssertNil(harness.store.preparedPlayback)
    XCTAssertNil(harness.store.errorMessage)
  }

  private func makeHarness(
    recommendations: RecommendationGate,
    streams: StreamGate
  ) -> AutoplayHarness {
    let library = LibraryStore(rootOverride: rootDirectory, cacheOverride: cacheDirectory)
    let feedback = FeedbackStore(rootDirectory: rootDirectory)
    let store = AutoplayStore(
      feedback: feedback,
      library: library,
      defaults: defaults,
      preferenceKey: "autoplayEnabled",
      now: { self.preparedAt },
      recommendationLoader: { _, item, _ in
        try await recommendations.call(item)
      },
      streamResolver: { _, item in
        try await streams.call(item)
      })
    return AutoplayHarness(store: store, feedback: feedback)
  }

  private func song(
    id: String,
    artist: String = "Example Artist",
    title: String? = nil,
    duration: Double? = 180
  ) -> SearchResult {
    SearchResult(
      id: id,
      title: title ?? "Song \(id)",
      artist: artist,
      duration: duration,
      webpageURLString: "https://www.youtube.com/watch?v=\(id)",
      thumbnailURLString: nil)
  }

  private func stream(id: String) -> PlaybackStream {
    PlaybackStream(
      audioURL: URL(string: "https://rr1.googlevideo.com/\(id).m4a")!,
      userAgent: "AutoplayStoreTests")
  }
}

@MainActor
private struct AutoplayHarness {
  let store: AutoplayStore
  let feedback: FeedbackStore
}

private enum TestFailure: LocalizedError, Sendable {
  case expected

  var errorDescription: String? { "Expected test failure" }
}

private struct ControlledRequest<Input: Sendable>: Sendable {
  let id: Int
  let input: Input
}

private actor ControlledOperation<Input: Sendable, Output: Sendable> {
  typealias Request = ControlledRequest<Input>

  private var nextID = 0
  private var continuations: [Int: CheckedContinuation<Output, Error>] = [:]
  private var unobservedRequests: [Request] = []
  private var requestWaiters: [CheckedContinuation<Request, Never>] = []

  func call(_ input: Input) async throws -> Output {
    let request = Request(id: nextID, input: input)
    nextID += 1
    return try await withCheckedThrowingContinuation { continuation in
      continuations[request.id] = continuation
      if requestWaiters.isEmpty {
        unobservedRequests.append(request)
      } else {
        requestWaiters.removeFirst().resume(returning: request)
      }
    }
  }

  func nextRequest() async -> Request {
    if !unobservedRequests.isEmpty {
      return unobservedRequests.removeFirst()
    }
    return await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func succeed(_ request: Request, with output: Output) {
    continuations.removeValue(forKey: request.id)?.resume(returning: output)
  }

  func fail(_ request: Request, with error: TestFailure) {
    continuations.removeValue(forKey: request.id)?.resume(throwing: error)
  }

  func callCount() -> Int { nextID }
}
