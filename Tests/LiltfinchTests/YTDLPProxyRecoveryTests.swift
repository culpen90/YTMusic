import Foundation
import XCTest

@testable import Liltfinch

final class YTDLPProxyRecoveryTests: XCTestCase {
  func testUnavailableLoopbackProxyRetriesSearchWithDirectConnection() async throws {
    let runner = ProxyScriptedRunner([
      .result(Self.refusedLoopbackProxyResult),
      .result(
        CommandResult(
          exitCode: 0,
          stdout:
            #"{"entries":[{"id":"nUsrYVxrDwI","title":"Choosin' Texas","channel":"Ella Langley","duration":422,"webpage_url":"https://www.youtube.com/watch?v=nUsrYVxrDwI"}]}"#,
          stderr: ""
        )),
    ])

    let values = try await makeService(runner: runner).search("elle langley", limit: 1)

    XCTAssertEqual(values.map(\.id), ["nUsrYVxrDwI"])
    assertSingleDirectRetry(runner.recordedArguments)
  }

  func testUnavailableLoopbackProxyRetriesDownloadWithDirectConnection() async throws {
    let runner = ProxyScriptedRunner([
      .result(Self.refusedLoopbackProxyResult),
      .successfulDownload(id: "nUsrYVxrDwI"),
    ])
    let stagingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiltfinchProxyTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: stagingDirectory) }
    let item = SearchResult(
      id: "nUsrYVxrDwI",
      title: "Choosin' Texas",
      artist: "Ella Langley",
      duration: 422,
      webpageURLString: "https://www.youtube.com/watch?v=nUsrYVxrDwI",
      thumbnailURLString: nil
    )

    let artifact = try await makeService(runner: runner).download(
      item,
      format: .best,
      stagingDirectory: stagingDirectory,
      onEvent: { _ in }
    )

    XCTAssertEqual(artifact.output.id, item.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.output.filepath))
    assertSingleDirectRetry(runner.recordedArguments)
  }

  func testNonProxySearchFailureIsNotRetried() async {
    let runner = ProxyScriptedRunner([
      .result(
        CommandResult(
          exitCode: 1,
          stdout: "",
          stderr: "ERROR: YouTube rejected the request"
        ))
    ])

    do {
      _ = try await makeService(runner: runner).search("elle langley", limit: 1)
      XCTFail("Expected the search to fail")
    } catch YTDLPError.commandFailed(let message) {
      XCTAssertEqual(message, "ERROR: YouTube rejected the request")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(runner.recordedArguments.count, 1)
  }

  func testUnavailableRemoteProxyIsNotBypassed() async {
    let runner = ProxyScriptedRunner([
      .result(
        CommandResult(
          exitCode: 1,
          stdout: "",
          stderr:
            "ERROR: Unable to connect to proxy; HTTPSConnection(host='proxy.example.com', port=443): Connection refused"
        ))
    ])

    do {
      _ = try await makeService(runner: runner).search("elle langley", limit: 1)
      XCTFail("Expected the search to fail")
    } catch YTDLPError.commandFailed {
      // An explicitly configured remote proxy must fail closed.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(runner.recordedArguments.count, 1)
  }

  func testFailedDirectRetryStopsAfterSecondAttempt() async {
    let runner = ProxyScriptedRunner([
      .result(Self.refusedLoopbackProxyResult),
      .result(
        CommandResult(
          exitCode: 1,
          stdout: "",
          stderr: "ERROR: Direct connection also failed"
        )),
    ])

    do {
      _ = try await makeService(runner: runner).search("elle langley", limit: 1)
      XCTFail("Expected the search to fail")
    } catch YTDLPError.commandFailed(let message) {
      XCTAssertEqual(message, "ERROR: Direct connection also failed")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    assertSingleDirectRetry(runner.recordedArguments)
  }

  func testSponsorBlockFailureRetriesPlaybackWithoutMusicSections() async throws {
    let runner = ProxyScriptedRunner([
      .result(
        CommandResult(
          exitCode: 1,
          stdout: "",
          stderr: "ERROR: Preprocessing: SponsorBlock API unavailable"
        )),
      .result(
        CommandResult(
          exitCode: 0,
          stdout:
            #"{"id":"nUsrYVxrDwI","url":"https://rr1.googlevideo.com/audio.m4a","http_headers":{},"duration":421}"#,
          stderr: ""
        )),
    ])
    let item = SearchResult(
      id: "nUsrYVxrDwI",
      title: "Choosin' Texas",
      artist: "Ella Langley",
      duration: 422,
      webpageURLString: "https://www.youtube.com/watch?v=nUsrYVxrDwI",
      thumbnailURLString: nil
    )

    let stream = try await makeService(runner: runner).resolvePlaybackStream(for: item)

    XCTAssertEqual(stream.timeline?.duration, 421)
    XCTAssertEqual(runner.recordedArguments.count, 2)
    XCTAssertTrue(runner.recordedArguments[0].contains("--sponsorblock-mark"))
    XCTAssertFalse(runner.recordedArguments[1].contains("--sponsorblock-mark"))
    XCTAssertFalse(runner.recordedArguments[1].contains { $0.contains("sponsorblock_chapters") })
  }

  func testCancellationNeverRetriesPlaybackWithoutMusicSections() async {
    let runner = ProxyScriptedRunner([.cancellation])
    let item = SearchResult(
      id: "nUsrYVxrDwI",
      title: "Choosin' Texas",
      artist: "Ella Langley",
      duration: 422,
      webpageURLString: "https://www.youtube.com/watch?v=nUsrYVxrDwI",
      thumbnailURLString: nil
    )

    do {
      _ = try await makeService(runner: runner).resolvePlaybackStream(for: item)
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Cancellation must not launch the plain-stream fallback.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(runner.recordedArguments.count, 1)
  }

  private static let refusedLoopbackProxyResult = CommandResult(
    exitCode: 1,
    stdout: "",
    stderr:
      "ERROR: Unable to download API page: Unable to connect to proxy; HTTPSConnection(host='127.0.0.1', port=4444): Connection refused"
  )

  private func makeService(runner: ProxyScriptedRunner) -> YTDLPService {
    YTDLPService(
      toolchain: ToolchainStatus(
        downloaderURL: URL(fileURLWithPath: "/usr/bin/true"),
        ffmpegURL: URL(fileURLWithPath: "/usr/bin/true")
      ),
      runner: runner
    )
  }

  private func assertSingleDirectRetry(
    _ calls: [[String]],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(calls.count, 2, file: file, line: line)
    guard calls.count == 2 else { return }
    XCTAssertFalse(calls[0].contains("--proxy"), file: file, line: line)
    XCTAssertEqual(value(after: "--proxy", in: calls[1]), "", file: file, line: line)
  }

  private func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }
}

private final class ProxyScriptedRunner: YTDLPCommandRunning, @unchecked Sendable {
  enum Response {
    case result(CommandResult)
    case successfulDownload(id: String)
    case cancellation
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
    currentDirectoryURL: URL?,
    environment _: [String: String]?,
    onLine: @escaping @Sendable (String, CommandOutputStream) -> Void
  ) async throws -> CommandResult {
    let response = try nextResponse(for: arguments)

    switch response {
    case .result(let result):
      return result
    case .successfulDownload(let id):
      let directory = try XCTUnwrap(currentDirectoryURL)
      let outputURL = directory.appendingPathComponent("\(id).m4a")
      try Data("test audio".utf8).write(to: outputURL)
      let payload = try JSONSerialization.data(
        withJSONObject: ["id": id, "filepath": outputURL.path, "ext": "m4a"]
      )
      onLine(
        YTDLPMarkerParser.resultPrefix + String(decoding: payload, as: UTF8.self),
        .stdout
      )
      return CommandResult(exitCode: 0, stdout: "", stderr: "")
    case .cancellation:
      throw CancellationError()
    }
  }

  private func nextResponse(for arguments: [String]) throws -> Response {
    lock.lock()
    defer { lock.unlock() }
    self.arguments.append(arguments)
    guard !responses.isEmpty else {
      throw YTDLPError.commandFailed("Unexpected downloader invocation")
    }
    return responses.removeFirst()
  }
}
