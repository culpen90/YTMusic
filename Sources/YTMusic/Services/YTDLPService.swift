import Foundation

enum YTDLPError: LocalizedError {
  case downloaderMissing
  case toolsMissing
  case invalidYouTubeURL
  case invalidRecommendationSeed
  case emptyQuery
  case commandFailed(String)
  case invalidResponse
  case missingOutput
  case noPlayableStream
  case noRecommendations
  case unsafeOutputPath

  var errorDescription: String? {
    switch self {
    case .downloaderMissing:
      "yt-dlp is required for playback. Open Settings to configure it."
    case .toolsMissing:
      "yt-dlp and FFmpeg are required. Open Settings to configure them."
    case .invalidYouTubeURL:
      "Enter a valid YouTube or youtu.be link."
    case .invalidRecommendationSeed:
      "This song cannot be used for autoplay recommendations."
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
    case .noRecommendations:
      "No autoplay recommendation is available for this song yet."
    case .unsafeOutputPath:
      "The downloader reported a file outside the temporary folder."
    }
  }
}

protocol YTDLPCommandRunning {
  func run(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?,
    environment: [String: String]?,
    onLine: @escaping @Sendable (String, CommandOutputStream) -> Void
  ) async throws -> CommandResult
}

extension SubprocessRunner: YTDLPCommandRunning {}

extension YTDLPCommandRunning {
  func run(executableURL: URL, arguments: [String]) async throws -> CommandResult {
    try await run(
      executableURL: executableURL,
      arguments: arguments,
      currentDirectoryURL: nil,
      environment: nil,
      onLine: { _, _ in }
    )
  }

  func run(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?,
    onLine: @escaping @Sendable (String, CommandOutputStream) -> Void
  ) async throws -> CommandResult {
    try await run(
      executableURL: executableURL,
      arguments: arguments,
      currentDirectoryURL: currentDirectoryURL,
      environment: nil,
      onLine: onLine
    )
  }
}

enum RecommendationSource: CaseIterable, Equatable {
  case youtubeMusicRadio
  case youtubeMix
  case search
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
  static let recommendationPrintTemplate =
    "%(.{id,title,channel,duration,webpage_url})j"

  static let playbackFormatSelector = [
    "bestaudio[ext=m4a][acodec^=mp4a][audio_channels<=2][protocol=https]",
    "bestaudio[acodec^=mp4a][audio_channels<=2][protocol^=m3u8]",
    "best[ext=mp4][acodec^=mp4a][audio_channels<=2][protocol=https]",
    "best[acodec^=mp4a][audio_channels<=2][protocol^=m3u8]",
  ].joined(separator: "/")

  private let toolchain: ToolchainStatus
  private let runner: any YTDLPCommandRunning
  private let decoder = JSONDecoder()

  init(
    toolchain: ToolchainStatus,
    runner: any YTDLPCommandRunning = SubprocessRunner()
  ) {
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

  func recommendations(
    for item: SearchResult,
    excluding history: AutoplayHistory = AutoplayHistory(),
    limit: Int = 15
  ) async throws -> [SearchResult] {
    guard limit > 0 else { return [] }
    guard toolchain.downloaderURL != nil else { throw YTDLPError.downloaderMissing }
    guard Self.isValidYouTubeVideoID(item.id) else {
      throw YTDLPError.invalidRecommendationSeed
    }

    var lastError: Error?
    var receivedValidResponse = false
    let desiredCount = min(limit, 49)
    let additionalCount = min(history.playedIDs.count, 49 - desiredCount)
    let sourceLimit = desiredCount + additionalCount

    for source in RecommendationSource.allCases {
      try Task.checkCancellation()
      do {
        let response = try await runJSON(
          Self.recommendationArguments(
            for: item,
            source: source,
            limit: sourceLimit,
            denoURL: toolchain.denoURL
          ))
        try Task.checkCancellation()
        let candidates = try Self.parseRecommendations(
          response,
          seedVideoID: item.id,
          limit: sourceLimit
        )
        receivedValidResponse = true
        let unheardCandidates = candidates.filter { !history.contains($0) }
        if !unheardCandidates.isEmpty {
          return Array(unheardCandidates.prefix(desiredCount))
        }
      } catch {
        if Self.isCancellation(error) { throw error }
        lastError = error
      }
    }

    if receivedValidResponse { throw YTDLPError.noRecommendations }
    throw lastError ?? YTDLPError.noRecommendations
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

    let result = try await runDownloaderCommand(
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

  static func isValidYouTubeVideoID(_ value: String) -> Bool {
    value.utf8.count == 11
      && value.utf8.allSatisfy { byte in
        (byte >= 97 && byte <= 122)
          || (byte >= 65 && byte <= 90)
          || (byte >= 48 && byte <= 57)
          || byte == 95
          || byte == 45
      }
  }

  static func canonicalYouTubeURL(forVideoID videoID: String) -> URL? {
    guard isValidYouTubeVideoID(videoID) else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "www.youtube.com"
    components.path = "/watch"
    components.queryItems = [URLQueryItem(name: "v", value: videoID)]
    return components.url
  }

  static func recommendationArguments(
    for item: SearchResult,
    source: RecommendationSource,
    limit: Int,
    denoURL: URL?
  ) throws -> [String] {
    guard isValidYouTubeVideoID(item.id), limit > 0 else {
      throw YTDLPError.invalidRecommendationSeed
    }

    let requestLimit = min(max(limit, 1), 49) + 1
    var arguments = [
      "--ignore-config",
      "--flat-playlist",
    ]
    if source != .search { arguments.append("--lazy-playlist") }
    arguments += [
      "--skip-download",
      "--no-warnings",
      "--playlist-start", "1",
      "--playlist-end", String(requestLimit),
    ]
    if let denoURL {
      arguments += ["--js-runtimes", "deno:\(denoURL.path)"]
    }
    arguments += [
      "--print", recommendationPrintTemplate,
      "--", try recommendationInput(for: item, source: source, requestLimit: requestLimit),
    ]
    return arguments
  }

  static func parseRecommendations(
    _ output: String,
    seedVideoID: String,
    limit: Int
  ) throws -> [SearchResult] {
    guard isValidYouTubeVideoID(seedVideoID) else {
      throw YTDLPError.invalidRecommendationSeed
    }
    guard limit > 0 else { return [] }

    let lines = output.split(whereSeparator: \Character.isNewline)
    var seen = Set<String>()
    var recommendations: [SearchResult] = []
    recommendations.reserveCapacity(min(limit, lines.count))

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      guard let data = trimmed.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(SearchResult.self, from: data)
      else {
        throw YTDLPError.invalidResponse
      }
      guard decoded.id != seedVideoID,
        isValidYouTubeVideoID(decoded.id),
        seen.insert(decoded.id).inserted,
        let canonicalURL = canonicalYouTubeURL(forVideoID: decoded.id)
      else {
        continue
      }

      recommendations.append(
        SearchResult(
          id: decoded.id,
          title: decoded.title,
          artist: decoded.artist,
          duration: decoded.duration,
          webpageURLString: canonicalURL.absoluteString,
          thumbnailURLString: decoded.thumbnailURLString
        ))
      if recommendations.count == limit { break }
    }
    return recommendations
  }

  private static func recommendationInput(
    for item: SearchResult,
    source: RecommendationSource,
    requestLimit: Int
  ) throws -> String {
    switch source {
    case .youtubeMusicRadio, .youtubeMix:
      var components = URLComponents()
      components.scheme = "https"
      components.host = source == .youtubeMusicRadio ? "music.youtube.com" : "www.youtube.com"
      components.path = "/watch"
      let playlistPrefix = source == .youtubeMusicRadio ? "RDAMVM" : "RD"
      components.queryItems = [
        URLQueryItem(name: "v", value: item.id),
        URLQueryItem(name: "list", value: playlistPrefix + item.id),
      ]
      guard let url = components.url else { throw YTDLPError.invalidRecommendationSeed }
      return url.absoluteString
    case .search:
      let artist = item.artist.trimmingCharacters(in: .whitespacesAndNewlines)
      let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let terms = [artist == "Unknown artist" ? nil : artist, title, "similar songs"]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      guard !terms.isEmpty else { throw YTDLPError.invalidRecommendationSeed }
      return "ytsearch\(requestLimit):\(terms)"
    }
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
    let result = try await runDownloaderCommand(
      executableURL: downloaderURL,
      arguments: arguments
    )
    guard result.exitCode == 0 else {
      throw YTDLPError.commandFailed(Self.readableError(from: result))
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func runDownloaderCommand(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    onLine: @escaping @Sendable (String, CommandOutputStream) -> Void = { _, _ in }
  ) async throws -> CommandResult {
    let result = try await runner.run(
      executableURL: executableURL,
      arguments: arguments,
      currentDirectoryURL: currentDirectoryURL,
      environment: nil,
      onLine: onLine
    )
    guard Self.shouldRetryWithoutRefusedLoopbackProxy(result, arguments: arguments) else {
      return result
    }

    try Task.checkCancellation()
    return try await runner.run(
      executableURL: executableURL,
      arguments: ["--proxy", ""] + arguments,
      currentDirectoryURL: currentDirectoryURL,
      environment: nil,
      onLine: onLine
    )
  }

  private static func shouldRetryWithoutRefusedLoopbackProxy(
    _ result: CommandResult,
    arguments: [String]
  ) -> Bool {
    guard result.exitCode != 0,
      !arguments.contains("--proxy"),
      !arguments.contains(where: { $0.hasPrefix("--proxy=") })
    else { return false }

    let loopbackPatterns = [
      "connection(host='127.0.0.1',",
      "connection(host=\"127.0.0.1\",",
      "connection(host='localhost',",
      "connection(host=\"localhost\",",
      "connection(host='::1',",
      "connection(host=\"::1\",",
    ]

    // Keep remote proxy failures fail closed. Retry only the refused local-helper shape.
    return result.stderr.split(whereSeparator: \Character.isNewline).contains { line in
      let message = line.lowercased()
      return message.contains("unable to connect to proxy")
        && message.contains("connection refused")
        && loopbackPatterns.contains { message.contains($0) }
    }
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
