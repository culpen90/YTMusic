import Foundation
import XCTest

@testable import YTMusic

final class RecommendationServiceTests: XCTestCase {
  func testBuildsRadioMixAndSearchArgumentsInFallbackOrder() throws {
    let seed = makeSeed()
    let denoURL = URL(fileURLWithPath: "/opt/homebrew/bin/deno")

    XCTAssertEqual(
      RecommendationSource.allCases,
      [.youtubeMusicRadio, .youtubeMix, .search]
    )

    let musicArguments = try YTDLPService.recommendationArguments(
      for: seed,
      source: .youtubeMusicRadio,
      limit: 15,
      denoURL: denoURL
    )
    XCTAssertTrue(musicArguments.contains("--flat-playlist"))
    XCTAssertTrue(musicArguments.contains("--lazy-playlist"))
    XCTAssertTrue(musicArguments.contains("--skip-download"))
    XCTAssertEqual(value(after: "--playlist-start", in: musicArguments), "1")
    XCTAssertEqual(value(after: "--playlist-end", in: musicArguments), "16")
    XCTAssertEqual(
      value(after: "--print", in: musicArguments),
      YTDLPService.recommendationPrintTemplate
    )
    XCTAssertEqual(
      value(after: "--js-runtimes", in: musicArguments),
      "deno:/opt/homebrew/bin/deno"
    )
    XCTAssertEqual(musicArguments[musicArguments.count - 2], "--")
    let musicURL = try XCTUnwrap(URLComponents(string: musicArguments.last!))
    XCTAssertEqual(musicURL.host, "music.youtube.com")
    XCTAssertEqual(queryValue("v", in: musicURL), seed.id)
    XCTAssertEqual(queryValue("list", in: musicURL), "RDAMVM\(seed.id)")

    let mixArguments = try YTDLPService.recommendationArguments(
      for: seed,
      source: .youtubeMix,
      limit: 15,
      denoURL: nil
    )
    let mixURL = try XCTUnwrap(URLComponents(string: mixArguments.last!))
    XCTAssertEqual(mixURL.host, "www.youtube.com")
    XCTAssertEqual(queryValue("list", in: mixURL), "RD\(seed.id)")

    let searchArguments = try YTDLPService.recommendationArguments(
      for: seed,
      source: .search,
      limit: 15,
      denoURL: nil
    )
    XCTAssertFalse(searchArguments.contains("--lazy-playlist"))
    XCTAssertEqual(
      searchArguments.last,
      "ytsearch16:Rick Astley Never Gonna Give You Up similar songs"
    )
  }

  func testParsesNDJSONWhileCanonicalizingFilteringAndDeduplicating() throws {
    let output = """
      {"id":"dQw4w9WgXcQ","title":"Seed","channel":"Seed Artist","duration":213,"webpage_url":"https://music.youtube.com/watch?v=dQw4w9WgXcQ"}
      {"id":"aaaaaaaaaaa","title":"First","channel":"Artist A","duration":180,"webpage_url":"https://malicious.example/redirect"}
      {"id":"aaaaaaaaaaa","title":"Duplicate","channel":"Artist A","duration":180,"webpage_url":"https://www.youtube.com/watch?v=aaaaaaaaaaa"}
      {"id":"not-valid","title":"Invalid ID","channel":"Artist B","duration":200,"webpage_url":"https://www.youtube.com/watch?v=not-valid"}
      {"id":"BBBBBBBBBBB","title":"Second","channel":"Artist B","duration":240,"webpage_url":"javascript:alert(1)"}
      {"id":"ccccccccccc","title":"Past Limit","channel":"Artist C","duration":210,"webpage_url":"https://www.youtube.com/watch?v=ccccccccccc"}
      """

    let values = try YTDLPService.parseRecommendations(
      output,
      seedVideoID: "dQw4w9WgXcQ",
      limit: 2
    )

    XCTAssertEqual(values.map(\.id), ["aaaaaaaaaaa", "BBBBBBBBBBB"])
    XCTAssertEqual(values.map(\.artist), ["Artist A", "Artist B"])
    XCTAssertEqual(
      values.map(\.webpageURLString),
      [
        "https://www.youtube.com/watch?v=aaaaaaaaaaa",
        "https://www.youtube.com/watch?v=BBBBBBBBBBB",
      ]
    )
  }

  func testRejectsMalformedNDJSON() {
    XCTAssertThrowsError(
      try YTDLPService.parseRecommendations(
        "not-json",
        seedVideoID: "dQw4w9WgXcQ",
        limit: 15
      ))
  }

  func testFallsBackFromMusicRadioThroughMixToSearch() async throws {
    let runner = ScriptedRecommendationRunner([
      .success(
        CommandResult(
          exitCode: 1,
          stdout: "",
          stderr: "ERROR: music radio unavailable"
        )),
      .success(
        CommandResult(
          exitCode: 0,
          stdout:
            #"{"id":"dQw4w9WgXcQ","title":"Seed","channel":"Rick Astley","webpage_url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}"#,
          stderr: ""
        )),
      .success(
        CommandResult(
          exitCode: 0,
          stdout:
            #"{"id":"aaaaaaaaaaa","title":"Fallback","channel":"Artist A","duration":180,"webpage_url":"https://www.youtube.com/watch?v=aaaaaaaaaaa"}"#,
          stderr: ""
        )),
    ])
    let service = YTDLPService(
      toolchain: ToolchainStatus(downloaderURL: URL(fileURLWithPath: "/usr/bin/true")),
      runner: runner
    )

    let values = try await service.recommendations(for: makeSeed())

    XCTAssertEqual(values.map(\.id), ["aaaaaaaaaaa"])
    let calls = runner.recordedArguments
    XCTAssertEqual(calls.count, 3)
    XCTAssertTrue(calls[0].last?.contains("music.youtube.com") == true)
    XCTAssertTrue(calls[0].last?.contains("RDAMVMdQw4w9WgXcQ") == true)
    XCTAssertTrue(calls[1].last?.contains("www.youtube.com") == true)
    XCTAssertTrue(calls[1].last?.contains("RDdQw4w9WgXcQ") == true)
    XCTAssertTrue(calls[2].last?.hasPrefix("ytsearch") == true)
  }

  func testCancellationNeverFallsBack() async {
    let runner = ScriptedRecommendationRunner([
      .failure(SubprocessError.cancelled),
      .success(CommandResult(exitCode: 0, stdout: "{}", stderr: "")),
    ])
    let service = YTDLPService(
      toolchain: ToolchainStatus(downloaderURL: URL(fileURLWithPath: "/usr/bin/true")),
      runner: runner
    )

    do {
      _ = try await service.recommendations(for: makeSeed())
      XCTFail("Expected cancellation")
    } catch SubprocessError.cancelled {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    XCTAssertEqual(runner.recordedArguments.count, 1)
  }

  func testSwiftCancellationNeverFallsBack() async {
    let runner = ScriptedRecommendationRunner([
      .failure(CancellationError()),
      .success(CommandResult(exitCode: 0, stdout: "{}", stderr: "")),
    ])
    let service = YTDLPService(
      toolchain: ToolchainStatus(downloaderURL: URL(fileURLWithPath: "/usr/bin/true")),
      runner: runner
    )

    do {
      _ = try await service.recommendations(for: makeSeed())
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    XCTAssertEqual(runner.recordedArguments.count, 1)
  }

  func testInvalidSeedIsRejectedBeforeLaunchingDownloader() async {
    let runner = ScriptedRecommendationRunner([])
    let service = YTDLPService(
      toolchain: ToolchainStatus(downloaderURL: URL(fileURLWithPath: "/usr/bin/true")),
      runner: runner
    )
    let invalidSeed = SearchResult(
      id: "too-short",
      title: "Invalid",
      artist: "Artist",
      duration: 60,
      webpageURLString: "https://www.youtube.com/watch?v=too-short",
      thumbnailURLString: nil
    )

    do {
      _ = try await service.recommendations(for: invalidSeed)
      XCTFail("Expected an invalid recommendation seed error")
    } catch YTDLPError.invalidRecommendationSeed {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    XCTAssertTrue(runner.recordedArguments.isEmpty)
  }

  private func makeSeed() -> SearchResult {
    SearchResult(
      id: "dQw4w9WgXcQ",
      title: "Never Gonna Give You Up",
      artist: "Rick Astley",
      duration: 213,
      webpageURLString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      thumbnailURLString: nil
    )
  }

  private func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }

  private func queryValue(_ name: String, in components: URLComponents) -> String? {
    components.queryItems?.first { $0.name == name }?.value
  }
}

private final class ScriptedRecommendationRunner: YTDLPCommandRunning, @unchecked Sendable {
  enum Response {
    case success(CommandResult)
    case failure(Error)
  }

  private let lock = NSLock()
  private var responses: [Response]
  private var arguments: [[String]] = []

  init(_ responses: [Response]) {
    self.responses = responses
  }

  var recordedArguments: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return arguments
  }

  func run(
    executableURL _: URL,
    arguments: [String],
    currentDirectoryURL _: URL?,
    environment _: [String: String]?,
    onLine _: @escaping @Sendable (String, CommandOutputStream) -> Void
  ) async throws -> CommandResult {
    try nextResponse(for: arguments)
  }

  private func nextResponse(for arguments: [String]) throws -> CommandResult {
    lock.lock()
    defer { lock.unlock() }
    self.arguments.append(arguments)
    guard !responses.isEmpty else {
      throw YTDLPError.commandFailed("Unexpected downloader invocation")
    }
    switch responses.removeFirst() {
    case .success(let result): return result
    case .failure(let error): throw error
    }
  }
}
