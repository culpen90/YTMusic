import Foundation

enum YTDLPError: LocalizedError {
  case toolsMissing
  case invalidYouTubeURL
  case emptyQuery
  case commandFailed(String)
  case invalidResponse
  case missingOutput
  case unsafeOutputPath

  var errorDescription: String? {
    switch self {
    case .toolsMissing:
      "yt-dlp and FFmpeg are required. Open Settings to configure them."
    case .invalidYouTubeURL:
      "Enter a valid YouTube or youtu.be link."
    case .emptyQuery:
      "Enter a song, artist, or YouTube link."
    case .commandFailed(let message):
      message
    case .invalidResponse:
      "The downloader returned metadata that could not be read."
    case .missingOutput:
      "The download finished without reporting an audio file."
    case .unsafeOutputPath:
      "The downloader reported a file outside the temporary folder."
    }
  }
}

struct DownloadArtifact {
  let metadata: SearchResult
  let output: DownloadOutput
  let stagingDirectory: URL
}

final class YTDLPService {
  private let toolchain: ToolchainStatus
  private let runner: SubprocessRunner
  private let decoder = JSONDecoder()

  init(toolchain: ToolchainStatus, runner: SubprocessRunner = SubprocessRunner()) {
    self.toolchain = toolchain
    self.runner = runner
  }

  func validatedToolchain() async throws -> ToolchainStatus {
    var checked = toolchain
    if let downloaderURL = toolchain.downloaderURL {
      do {
        let result = try await runner.run(
          executableURL: downloaderURL, arguments: ["--version"])
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0, !version.isEmpty {
          checked.downloaderVersion = version
        } else {
          checked.downloaderURL = nil
          checked.downloaderVersion = nil
        }
      } catch {
        if Self.isCancellation(error) { throw error }
        checked.downloaderURL = nil
        checked.downloaderVersion = nil
      }
    }
    try Task.checkCancellation()
    if let ffmpegURL = toolchain.ffmpegURL {
      do {
        let result = try await runner.run(executableURL: ffmpegURL, arguments: ["-version"])
        let version = result.stdout.split(separator: "\n").first.map(String.init)
        if result.exitCode == 0, version != nil {
          checked.ffmpegVersion = version
        } else {
          checked.ffmpegURL = nil
          checked.ffmpegVersion = nil
        }
      } catch {
        if Self.isCancellation(error) { throw error }
        checked.ffmpegURL = nil
        checked.ffmpegVersion = nil
      }
    }
    return checked
  }

  func search(_ query: String, limit: Int = 15) async throws -> [SearchResult] {
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw YTDLPError.emptyQuery }
    let response = try await runJSON(
      [
        "--ignore-config",
        "--no-cache-dir",
        "--flat-playlist",
        "--skip-download",
        "--dump-single-json",
        "--playlist-end", String(limit),
        "--no-warnings",
      ] + javascriptRuntimeArguments + ["--", "ytsearch\(limit):\(value)"])
    guard let data = response.data(using: .utf8),
      let envelope = try? decoder.decode(SearchEnvelope.self, from: data)
    else {
      throw YTDLPError.invalidResponse
    }
    return envelope.entries
  }

  func probe(url: URL) async throws -> SearchResult {
    guard Self.isYouTubeURL(url) else { throw YTDLPError.invalidYouTubeURL }
    let response = try await runJSON(
      [
        "--ignore-config",
        "--no-cache-dir",
        "--no-playlist",
        "--skip-download",
        "--dump-single-json",
        "--no-warnings",
      ] + javascriptRuntimeArguments + ["--", url.absoluteString])
    guard let data = response.data(using: .utf8),
      let metadata = try? decoder.decode(SearchResult.self, from: data)
    else {
      throw YTDLPError.invalidResponse
    }
    return metadata
  }

  func download(
    _ item: SearchResult,
    format: AudioFormat,
    stagingDirectory: URL,
    onEvent: @escaping @Sendable (YTDLPEvent) -> Void
  ) async throws -> DownloadArtifact {
    guard let downloaderURL = toolchain.downloaderURL,
      let ffmpegURL = toolchain.ffmpegURL
    else {
      throw YTDLPError.toolsMissing
    }
    guard let url = item.webpageURL, Self.isYouTubeURL(url) else {
      throw YTDLPError.invalidYouTubeURL
    }

    try FileManager.default.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: true
    )

    let eventBox = DownloadEventBox(fallbackMetadata: item, onEvent: onEvent)
    var arguments = [
      "--ignore-config",
      "--no-cache-dir",
      "--no-playlist",
      "--no-simulate",
    ]
    arguments += javascriptRuntimeArguments
    arguments += [
      "--ffmpeg-location", ffmpegURL.path,
      "--format", "bestaudio/best",
      "--extract-audio",
    ]
    arguments += format.ytDLPArguments
    arguments += [
      "--embed-metadata",
      "--write-thumbnail",
      "--convert-thumbnails", "jpg",
      "--no-embed-info-json",
      "--paths", "home:\(stagingDirectory.path)",
      "--paths", "temp:\(stagingDirectory.path)",
      "--output", "%(id)s.%(ext)s",
      "--continue",
      "--no-overwrites",
      "--retries", "3",
      "--fragment-retries", "3",
      "--retry-sleep", "http:exp=1:20",
      "--retry-sleep", "fragment:exp=1:20",
      "--socket-timeout", "30",
      "--newline",
      "--color", "never",
      "--progress",
      "--progress-delta", "0.2",
      "--progress-template", "download:\(YTDLPMarkerParser.progressPrefix)%(progress)j",
      "--progress-template", "postprocess:\(YTDLPMarkerParser.postprocessPrefix)%(progress)j",
      "--print",
      "before_dl:\(YTDLPMarkerParser.metadataPrefix){\"id\":%(id)j,\"title\":%(title)j,\"channel\":%(channel)j,\"duration\":%(duration)j,\"webpage_url\":%(webpage_url)j,\"thumbnail\":%(thumbnail)j}",
      "--print", #"after_move:YTMSIC_RESULT:{"id":%(id)j,"filepath":%(filepath)j,"ext":%(ext)j}"#,
      "--", url.absoluteString,
    ]

    let result = try await runner.run(
      executableURL: downloaderURL,
      arguments: arguments,
      currentDirectoryURL: stagingDirectory
    ) { line, stream in
      if let event = YTDLPMarkerParser.parse(line) {
        if stream == .stderr {
          switch event {
          case .metadata, .result: return
          case .progress, .postprocessing: break
          }
        }
        eventBox.receive(event)
      }
    }

    guard result.exitCode == 0 else {
      throw YTDLPError.commandFailed(Self.readableError(from: result))
    }
    let eventSnapshot = eventBox.snapshot()
    guard let output = eventSnapshot.output else { throw YTDLPError.missingOutput }
    guard output.id == item.id else { throw YTDLPError.unsafeOutputPath }

    let reportedURL = URL(fileURLWithPath: output.filepath).standardizedFileURL
    let root = stagingDirectory.standardizedFileURL
    guard root.resolvingSymlinksInPath().path == root.path,
      reportedURL.deletingLastPathComponent() == root,
      reportedURL.resolvingSymlinksInPath().path == reportedURL.path,
      let values = try? reportedURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ]),
      values.isRegularFile == true,
      values.isSymbolicLink != true
    else { throw YTDLPError.unsafeOutputPath }

    return DownloadArtifact(
      metadata: eventSnapshot.metadata,
      output: output,
      stagingDirectory: stagingDirectory
    )
  }

  static func isYouTubeURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      let host = url.host?.lowercased()
    else { return false }
    return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
  }

  static func videoID(from url: URL) -> String? {
    guard isYouTubeURL(url), let host = url.host?.lowercased() else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    if host == "youtu.be" {
      return url.pathComponents.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
    }
    if let value = components?.queryItems?.first(where: { $0.name == "v" })?.value,
      !value.isEmpty
    {
      return value
    }
    let parts = url.pathComponents.filter { $0 != "/" }
    if parts.count >= 2, ["embed", "shorts", "live"].contains(parts[0]), !parts[1].isEmpty {
      return parts[1]
    }
    return nil
  }

  private var javascriptRuntimeArguments: [String] {
    guard let denoURL = toolchain.denoURL else { return [] }
    return ["--js-runtimes", "deno:\(denoURL.path)"]
  }

  private func runJSON(_ arguments: [String]) async throws -> String {
    guard let downloaderURL = toolchain.downloaderURL else { throw YTDLPError.toolsMissing }
    let result = try await runner.run(executableURL: downloaderURL, arguments: arguments)
    guard result.exitCode == 0 else {
      throw YTDLPError.commandFailed(Self.readableError(from: result))
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func readableError(from result: CommandResult) -> String {
    let lines = result.stderr
      .split(separator: "\n")
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return lines.last(where: { $0.contains("ERROR:") })
      ?? lines.last
      ?? "yt-dlp exited with code \(result.exitCode)."
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

private final class DownloadEventBox: @unchecked Sendable {
  private let lock = NSLock()
  private var metadata: SearchResult
  private var output: DownloadOutput?
  private let onEvent: @Sendable (YTDLPEvent) -> Void

  init(fallbackMetadata: SearchResult, onEvent: @escaping @Sendable (YTDLPEvent) -> Void) {
    metadata = fallbackMetadata
    self.onEvent = onEvent
  }

  func receive(_ event: YTDLPEvent) {
    lock.lock()
    switch event {
    case .metadata(let value): metadata = value
    case .result(let value): output = value
    default: break
    }
    lock.unlock()
    onEvent(event)
  }

  func snapshot() -> (metadata: SearchResult, output: DownloadOutput?) {
    lock.lock()
    defer { lock.unlock() }
    return (metadata, output)
  }
}
