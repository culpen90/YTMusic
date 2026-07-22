import Foundation
import Observation

@MainActor
@Observable
final class DownloadManager {
  private(set) var jobs: [DownloadJob] = []

  private let toolchain: ToolchainStore
  private let library: LibraryStore
  private var activeTask: Task<Void, Never>?
  private var activeJobID: UUID?
  private var completions: [UUID: (Result<Track, Error>) -> Void] = [:]
  private var isShuttingDown = false

  init(toolchain: ToolchainStore, library: LibraryStore) {
    self.toolchain = toolchain
    self.library = library
  }

  var activeCount: Int { jobs.filter { $0.phase.isActive }.count }

  @discardableResult
  func enqueue(
    _ result: SearchResult,
    intent: DownloadIntent,
    completion: @escaping (Result<Track, Error>) -> Void = { _ in }
  ) -> UUID? {
    guard !isShuttingDown else {
      completion(.failure(SubprocessError.cancelled))
      return nil
    }
    if intent == .keep, let existing = library.track(withID: result.id) {
      completion(.success(existing))
      return nil
    }
    let job = DownloadJob(result: result, intent: intent)
    if intent == .playOnce,
      let firstQueued = jobs.firstIndex(where: { $0.phase == .queued })
    {
      jobs.insert(job, at: firstQueued)
    } else {
      jobs.append(job)
    }
    completions[job.id] = completion
    startNextIfNeeded()
    return job.id
  }

  func cancel(_ jobID: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
    if activeJobID == jobID {
      activeTask?.cancel()
    } else if jobs[index].phase == .queued {
      jobs[index].phase = .cancelled
      jobs[index].completedAt = Date()
      completions.removeValue(forKey: jobID)?(.failure(SubprocessError.cancelled))
    }
  }

  func retry(_ jobID: UUID) {
    guard let job = jobs.first(where: { $0.id == jobID }) else { return }
    enqueue(job.result, intent: job.intent)
  }

  func clearFinished() {
    jobs.removeAll { !$0.phase.isActive }
  }

  func shutdown() async {
    isShuttingDown = true
    for index in jobs.indices where jobs[index].phase == .queued {
      jobs[index].phase = .cancelled
      jobs[index].completedAt = Date()
      completions.removeValue(forKey: jobs[index].id)?(.failure(SubprocessError.cancelled))
    }
    let task = activeTask
    task?.cancel()
    if let task {
      await task.value
    }
    activeTask = nil
    activeJobID = nil
  }

  private func startNextIfNeeded() {
    guard !isShuttingDown, activeTask == nil,
      let nextID = jobs.first(where: { $0.phase == .queued })?.id
    else { return }
    activeJobID = nextID
    activeTask = Task { [weak self] in
      await self?.run(jobID: nextID)
    }
  }

  private func run(jobID: UUID) async {
    guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
      finishQueueCycle()
      return
    }
    jobs[index].phase = .preparing
    var staging: URL?
    do {
      guard toolchain.status.isReady else { throw YTDLPError.toolsMissing }
      let directory = try library.makeStagingDirectory(jobID: jobID)
      staging = directory
      let item = jobs[index].result
      let format =
        AudioFormat(
          rawValue: UserDefaults.standard.string(forKey: "audioFormat") ?? "best"
        ) ?? .best
      let artifact = try await YTDLPService(toolchain: toolchain.status).download(
        item,
        format: format,
        stagingDirectory: directory
      ) { [weak self] event in
        Task { @MainActor in self?.apply(event, to: jobID) }
      }
      try Task.checkCancellation()
      update(jobID) { $0.phase = .importing }
      let intent = jobs.first(where: { $0.id == jobID })?.intent ?? .playOnce
      let track = try library.importArtifact(artifact, intent: intent, jobID: jobID)
      update(jobID) {
        $0.phase = .completed
        $0.progress = 1
        $0.completedAt = Date()
      }
      completions.removeValue(forKey: jobID)?(.success(track))
    } catch {
      if let staging { library.removeStagingDirectory(staging) }
      let cancelled: Bool
      if error is CancellationError {
        cancelled = true
      } else if let subprocessError = error as? SubprocessError,
        case .cancelled = subprocessError
      {
        cancelled = true
      } else {
        cancelled = false
      }
      update(jobID) {
        $0.phase = cancelled ? .cancelled : .failed
        $0.errorMessage = cancelled ? nil : error.localizedDescription
        $0.completedAt = Date()
      }
      completions.removeValue(forKey: jobID)?(.failure(error))
    }
    finishQueueCycle()
  }

  private func finishQueueCycle() {
    activeTask = nil
    activeJobID = nil
    if !isShuttingDown {
      startNextIfNeeded()
    }
  }

  private func apply(_ event: YTDLPEvent, to jobID: UUID) {
    guard activeJobID == jobID,
      let job = jobs.first(where: { $0.id == jobID }),
      [.preparing, .downloading, .converting].contains(job.phase)
    else { return }
    update(jobID) { job in
      switch event {
      case .progress(let progress):
        job.phase = .downloading
        job.progress = progress.fraction
        job.downloadedBytes = progress.downloadedBytes
        job.totalBytes = progress.totalBytes ?? progress.totalBytesEstimate
        job.speed = progress.speed
        job.eta = progress.eta
      case .postprocessing:
        job.phase = .converting
        job.progress = nil
      case .metadata, .result:
        break
      }
    }
  }

  private func update(_ jobID: UUID, change: (inout DownloadJob) -> Void) {
    guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
    change(&jobs[index])
  }
}
