import Foundation
import Observation

enum AutoplayPreparationError: LocalizedError {
  case noRecommendation

  var errorDescription: String? {
    "No autoplay recommendation is available for this song yet."
  }
}

struct PreparedPlayback {
  enum Source {
    case local(Track)
    case stream(PlaybackStream)
  }

  let item: SearchResult
  let source: Source
  let preparedAt: Date

  var localTrack: Track? {
    guard case .local(let track) = source else { return nil }
    return track
  }

  var resolvedStream: PlaybackStream? {
    guard case .stream(let stream) = source else { return nil }
    return stream
  }
}

@MainActor
@Observable
final class AutoplayStore {
  typealias RecommendationLoader =
    @Sendable (ToolchainStatus, SearchResult, AutoplayHistory) async throws ->
    [SearchResult]
  typealias StreamResolver =
    @Sendable (ToolchainStatus, SearchResult) async throws -> PlaybackStream

  private(set) var isEnabled: Bool
  private(set) var isPreparing = false
  private(set) var nextItem: SearchResult?
  private(set) var preparedPlayback: PreparedPlayback?
  private(set) var errorMessage: String?

  var onPreparationFinished: (() -> Void)?

  private let feedback: FeedbackStore
  private let library: LibraryStore
  private let defaults: UserDefaults
  private let preferenceKey: String
  private let now: @Sendable () -> Date
  private let recommendationLoader: RecommendationLoader
  private let streamResolver: StreamResolver
  private var preparationTask: Task<Void, Never>?
  private var taskToAwait: Task<Void, Never>?
  private var generation = UUID()
  private var isShuttingDown = false
  private var playbackHistory = AutoplayHistory()

  init(
    feedback: FeedbackStore,
    library: LibraryStore,
    defaults: UserDefaults = .standard,
    preferenceKey: String = "autoplayEnabled",
    now: @escaping @Sendable () -> Date = { Date() },
    recommendationLoader: @escaping RecommendationLoader = { toolchain, item, history in
      try await YTDLPService(toolchain: toolchain).recommendations(
        for: item,
        excluding: history)
    },
    streamResolver: @escaping StreamResolver = { toolchain, item in
      try await YTDLPService(toolchain: toolchain).resolvePlaybackStream(for: item)
    }
  ) {
    self.feedback = feedback
    self.library = library
    self.defaults = defaults
    self.preferenceKey = preferenceKey
    self.now = now
    self.recommendationLoader = recommendationLoader
    self.streamResolver = streamResolver
    isEnabled = defaults.object(forKey: preferenceKey) as? Bool ?? true
  }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: preferenceKey)
  }

  func recordPlayback(of item: SearchResult) {
    playbackHistory.record(item)
  }

  func prepareNext(
    after currentItem: SearchResult,
    queuedNext: SearchResult?,
    excluding excludedIDs: Set<String> = [],
    toolchain: ToolchainStatus,
    waitingFor barrierTask: Task<Void, Never>? = nil
  ) {
    guard !isShuttingDown else { return }
    let previousTask = invalidatePreparation(clearPrepared: true)
    guard queuedNext != nil || isEnabled else { return }
    taskToAwait = nil

    let requestGeneration = UUID()
    generation = requestGeneration
    isPreparing = true
    nextItem = queuedNext
    errorMessage = nil
    var history = playbackHistory
    history.record(currentItem)
    history.exclude(ids: excludedIDs)

    let task = Task { [weak self] in
      if let previousTask { await previousTask.value }
      if let barrierTask { await barrierTask.value }
      guard let self else { return }

      do {
        try Task.checkCancellation()
        let candidates: [SearchResult]
        if let queuedNext {
          candidates = [queuedNext]
        } else {
          let loadedCandidates = try await self.recommendationLoader(
            toolchain,
            currentItem,
            history)
          try Task.checkCancellation()
          guard self.generation == requestGeneration, !self.isShuttingDown else { return }
          candidates = self.feedback.rankedRecommendations(
            from: loadedCandidates,
            excluding: history.playedIDs
          )
          .filter { !history.contains($0) }
          guard !candidates.isEmpty else {
            throw AutoplayPreparationError.noRecommendation
          }
        }

        var prepared: PreparedPlayback?
        var lastResolutionError: Error?
        for item in candidates {
          try Task.checkCancellation()
          guard self.generation == requestGeneration, !self.isShuttingDown else { return }
          self.nextItem = item

          if let localTrack = self.library.track(withID: item.id),
            FileManager.default.fileExists(atPath: localTrack.audioURL.path)
          {
            prepared = PreparedPlayback(
              item: item, source: .local(localTrack), preparedAt: self.now())
            break
          }

          do {
            let stream = try await self.streamResolver(toolchain, item)
            try Task.checkCancellation()
            guard self.generation == requestGeneration, !self.isShuttingDown else { return }
            prepared = PreparedPlayback(
              item: item, source: .stream(stream), preparedAt: self.now())
            break
          } catch {
            if Self.isCancellation(error) { throw error }
            try Task.checkCancellation()
            guard self.generation == requestGeneration, !self.isShuttingDown else { return }
            lastResolutionError = error
          }
        }

        guard let prepared else {
          throw lastResolutionError ?? AutoplayPreparationError.noRecommendation
        }
        guard self.generation == requestGeneration, !self.isShuttingDown else { return }
        self.preparedPlayback = prepared
        self.isPreparing = false
        self.preparationTask = nil
        self.taskToAwait = nil
        self.onPreparationFinished?()
      } catch {
        guard self.generation == requestGeneration, !self.isShuttingDown else { return }
        self.preparedPlayback = nil
        self.nextItem = nil
        self.isPreparing = false
        self.preparationTask = nil
        self.taskToAwait = nil
        if !Self.isCancellation(error) {
          self.errorMessage = error.localizedDescription
        }
        self.onPreparationFinished?()
      }
    }
    preparationTask = task
  }

  func consumePrepared(matching expectedItemID: String? = nil) -> PreparedPlayback? {
    guard let preparedPlayback else { return nil }
    if let expectedItemID, preparedPlayback.item.id != expectedItemID { return nil }

    if preparedPlayback.resolvedStream != nil,
      now().timeIntervalSince(preparedPlayback.preparedAt) > 60 * 60
    {
      _ = invalidatePreparation(clearPrepared: true)
      return nil
    }

    generation = UUID()
    self.preparedPlayback = nil
    nextItem = nil
    errorMessage = nil
    return preparedPlayback
  }

  @discardableResult
  func cancelPreparation(clearPrepared: Bool = true) -> Task<Void, Never>? {
    invalidatePreparation(clearPrepared: clearPrepared)
  }

  func shutdown() async {
    isShuttingDown = true
    onPreparationFinished = nil
    let task = invalidatePreparation(clearPrepared: true)
    taskToAwait = nil
    if let task { await task.value }
  }

  @discardableResult
  private func invalidatePreparation(clearPrepared: Bool) -> Task<Void, Never>? {
    generation = UUID()
    let task = preparationTask ?? taskToAwait
    task?.cancel()
    taskToAwait = task
    preparationTask = nil
    isPreparing = false
    if clearPrepared {
      preparedPlayback = nil
      nextItem = nil
      errorMessage = nil
    }
    return task
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let subprocessError = error as? SubprocessError,
      case .cancelled = subprocessError
    {
      return true
    }
    return false
  }
}
