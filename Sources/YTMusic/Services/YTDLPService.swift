import Foundation

enum YTDLPError: LocalizedError {
  case downloaderMissing
  case toolsMissing
  case invalidYouTubeURL
  case emptyQuery
  case commandFailed(String)
  case invalidResponse
  case missingOutput
  case noPlayableStream
  case unsafeOutputPath

  var errorDescription: String? {
    switch self {
    case .downloaderMissing:
      "yt-dlp is required for playback. Open Settings to configure it."
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
    case .noPlayableStream:
      "A compatible audio stream could not be prepared for playback."
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

private struct PlaybackStreamOutput: Decodable {
  let url: String
  let httpHeaders: [String: String]?

  private enum CodingKeys: String, CodingKey {
    case url
    case httpHeaders = "http_headers"
  }
}

final class YTDLPService {
  static let playbackFormatSelector = [
    "bestaudio[ext=m4a][acodec^=mp4a][audio_channels<=2][protocol=https]",
    "bestaudio[acodec^=mp4a][audio_channels<=2][protocol^=m3u8]",
    "best[ext=mp4][acodec^=mp4a][audio_channels<=2][protocol=https]",
    "best[acodec^=mp4a][audio_channels<=2][protocol^=m3u8]",
  ].joined(separator: "/")

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

  func resolvePlaybackStream(for item: SearchResult) async throws -> PlaybackStream {
    guard toolchain.downloaderURL != nil else { throw YTDLPError.downloaderMissing }
    guard let url = item.webpageURL, Self.isYouTubeURL(url) else {
      throw YTDLPError.invalidYouTubeURL
    }

    let response = try await runJSON(
      Self.playbackStreamArguments(for: url, denoURL: toolchain.denoURL))
    try Task.checkCancellation()
    return try Self.parsePlaybackStream(response)
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

  static func playbackStreamArguments(for url: URL, denoURL: URL?) -> [String] {
    var arguments = [
      "--ignore-config",
      "--no-playlist",
      "--skip-download",
      "--no-warnings",
    ]
    if let denoURL {
      arguments += ["--js-runtimes", "deno:\(denoURL.path)"]
    }
    arguments += [
      "--format", playbackFormatSelector,
      "--print", #"{"url":%(url)j,"http_headers":%(http_headers)j}"#,
      "--", url.absoluteString,
    ]
    return arguments
  }

  static func parsePlaybackStream(_ output: String) throws -> PlaybackStream {
    let lines =
      output
      .split(whereSeparator: \Character.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard lines.count == 1,
      let data = lines[0].data(using: .utf8),
      let streamOutput = try? JSONDecoder().decode(PlaybackStreamOutput.self, from: data),
      let components = URLComponents(string: streamOutput.url),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(),
      isAllowedPlaybackHost(host),
      components.port == nil || components.port == 443,
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      let url = components.url
    else {
      throw YTDLPError.noPlayableStream
    }

    let userAgent = streamOutput.httpHeaders?.first {
      $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame
    }?.value
    guard
      userAgent.map({ value in
        value.count <= 1_024
          && !value.unicodeScalars.contains(where: { $0.value == 0x0A || $0.value == 0x0D })
      }) ?? true
    else {
      throw YTDLPError.noPlayableStream
    }
    return PlaybackStream(audioURL: url, userAgent: userAgent)
  }

  private static func isAllowedPlaybackHost(_ host: String) -> Bool {
    host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
      || host == "youtube.com" || host.hasSuffix(".youtube.com")
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
