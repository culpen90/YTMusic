import Foundation
import Observation

@MainActor
@Observable
final class SearchStore {
  var query = ""
  var results: [SearchResult] = []
  var isLoading = false
  var errorMessage: String?

  private let toolchain: ToolchainStore
  private var operations: [UUID: Task<Void, Never>] = [:]
  private var activeOperationID: UUID?
  private var isShuttingDown = false

  init(toolchain: ToolchainStore) {
    self.toolchain = toolchain
  }

  func submit() {
    let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else {
      results = []
      errorMessage = nil
      return
    }
    guard !isShuttingDown else { return }
    cancelSupersededOperations()
    let operationID = UUID()
    activeOperationID = operationID
    isLoading = true
    errorMessage = nil

    operations[operationID] = Task { [weak self] in
      guard let self else { return }
      do {
        let service = YTDLPService(toolchain: self.toolchain.status)
        let values: [SearchResult]
        if let url = URL(string: input), url.scheme != nil {
          values = [try await service.probe(url: url)]
        } else {
          values = try await service.search(input)
        }
        try Task.checkCancellation()
        guard self.activeOperationID == operationID else {
          self.finish(operationID)
          return
        }
        self.results = values
      } catch is CancellationError {
        // A newer request or app shutdown superseded this search.
      } catch SubprocessError.cancelled {
        // A newer request or app shutdown superseded this search.
      } catch {
        if self.activeOperationID == operationID {
          self.results = []
          self.errorMessage = error.localizedDescription
        }
      }
      self.finish(operationID)
    }
  }

  @discardableResult
  func resolveURLLines(_ text: String, completion: @escaping ([SearchResult]) -> Void) -> UUID? {
    let lines =
      text
      .split(whereSeparator: \Character.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !lines.isEmpty, !isShuttingDown else {
      completion([])
      return nil
    }

    cancelSupersededOperations()
    let operationID = UUID()
    activeOperationID = operationID
    isLoading = true
    errorMessage = nil
    operations[operationID] = Task { [weak self] in
      guard let self else { return }
      var resolved: [SearchResult] = []
      var failures: [String] = []
      let service = YTDLPService(toolchain: self.toolchain.status)
      do {
        for line in lines {
          try Task.checkCancellation()
          guard let url = URL(string: line), let videoID = YTDLPService.videoID(from: url) else {
            failures.append("Not a YouTube video URL: \(line)")
            continue
          }
          do {
            resolved.append(try await service.probe(url: url))
          } catch is CancellationError {
            throw CancellationError()
          } catch SubprocessError.cancelled {
            throw SubprocessError.cancelled
          } catch {
            resolved.append(
              SearchResult(
                id: videoID,
                title: "YouTube video \(videoID)",
                artist: "YouTube",
                duration: nil,
                webpageURLString: url.absoluteString,
                thumbnailURLString: nil
              ))
          }
        }
        try Task.checkCancellation()
        guard self.activeOperationID == operationID else {
          self.finish(operationID)
          return
        }
        if !failures.isEmpty {
          self.errorMessage = failures.prefix(3).joined(separator: "\n")
        }
        completion(resolved)
      } catch {
        if self.activeOperationID == operationID { completion([]) }
      }
      self.finish(operationID)
    }
    return operationID
  }

  func cancel(_ operationID: UUID) {
    operations[operationID]?.cancel()
    if activeOperationID == operationID {
      activeOperationID = nil
      isLoading = false
    }
  }

  func shutdown() async {
    isShuttingDown = true
    let tasks = Array(operations.values)
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    operations.removeAll()
    activeOperationID = nil
    isLoading = false
  }

  private func cancelSupersededOperations() {
    for task in operations.values { task.cancel() }
  }

  private func finish(_ operationID: UUID) {
    operations.removeValue(forKey: operationID)
    if activeOperationID == operationID {
      activeOperationID = nil
      isLoading = false
    }
  }
}
