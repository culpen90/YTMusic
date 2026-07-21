import Foundation
import Observation

@MainActor
@Observable
final class ToolchainStore {
  var status = ToolchainStatus()
  var isChecking = false
  var isInstalling = false
  var setupLog = ""
  var errorMessage: String?

  private var refreshTask: Task<Void, Never>?
  private var refreshID: UUID?
  private var installTask: Task<Void, Never>?
  private var installID: UUID?
  private var isShuttingDown = false

  init() {
    status = ExecutableResolver.detect()
  }

  func refresh() {
    guard !isShuttingDown else { return }
    refreshTask?.cancel()
    let operationID = UUID()
    refreshID = operationID
    isChecking = true
    errorMessage = nil
    let detected = ExecutableResolver.detect()
    refreshTask = Task { [weak self] in
      guard let self else { return }
      do {
        let validated = try await YTDLPService(toolchain: detected).validatedToolchain()
        try Task.checkCancellation()
        guard self.refreshID == operationID else { return }
        self.status = validated
      } catch is CancellationError {
        // A newer refresh or app shutdown superseded this check.
      } catch SubprocessError.cancelled {
        // A newer refresh or app shutdown superseded this check.
      } catch {
        guard self.refreshID == operationID else { return }
        self.errorMessage = error.localizedDescription
      }
      if self.refreshID == operationID {
        self.isChecking = false
        self.refreshID = nil
        self.refreshTask = nil
      }
    }
  }

  func installWithHomebrew() {
    guard !isShuttingDown, installTask == nil else { return }
    guard let brew = Self.brewURL else {
      errorMessage =
        "Homebrew was not found. Install yt-dlp and FFmpeg manually, then choose their paths in Settings."
      return
    }

    let operationID = UUID()
    installID = operationID
    isInstalling = true
    setupLog = "Starting Homebrew…\n"
    errorMessage = nil
    installTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await SubprocessRunner().run(
          executableURL: brew,
          arguments: ["install", "yt-dlp", "ffmpeg"]
        ) { [weak self] line, _ in
          Task { @MainActor in
            guard let self, self.installID == operationID else { return }
            self.appendSetupLine(line)
          }
        }
        try Task.checkCancellation()
        guard self.installID == operationID else { return }
        if result.exitCode != 0 {
          self.errorMessage =
            result.stderr.split(separator: "\n").last.map(String.init)
            ?? "Homebrew could not install the tools."
        }
      } catch is CancellationError {
        // App shutdown owns cancellation and cleanup.
      } catch SubprocessError.cancelled {
        // App shutdown owns cancellation and cleanup.
      } catch {
        guard self.installID == operationID else { return }
        self.errorMessage = error.localizedDescription
      }

      guard self.installID == operationID else { return }
      self.installID = nil
      self.installTask = nil
      self.isInstalling = false
      self.refresh()
    }
  }

  func shutdown() async {
    isShuttingDown = true
    let installTask = installTask
    let refreshTask = refreshTask
    installTask?.cancel()
    refreshTask?.cancel()
    if let installTask { await installTask.value }
    if let refreshTask { await refreshTask.value }
    self.installTask = nil
    self.refreshTask = nil
    installID = nil
    refreshID = nil
    isInstalling = false
    isChecking = false
  }

  static var brewURL: URL? {
    ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
      .map(URL.init(fileURLWithPath:))
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  private func appendSetupLine(_ line: String) {
    setupLog += line + "\n"
    if setupLog.count > 200_000 {
      setupLog = "[Earlier output omitted]\n" + setupLog.suffix(160_000)
    }
  }
}
