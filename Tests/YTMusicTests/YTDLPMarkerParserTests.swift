import XCTest

@testable import YTMusic

final class YTDLPMarkerParserTests: XCTestCase {
  func testParsesMachineReadableProgress() throws {
    let line =
      #"YTMSIC_PROGRESS:{"status":"downloading","downloaded_bytes":50,"total_bytes":200,"speed":1024,"eta":4}"#
    guard case .progress(let progress) = YTDLPMarkerParser.parse(line) else {
      return XCTFail("Expected progress event")
    }
    XCTAssertEqual(progress.downloadedBytes, 50)
    XCTAssertEqual(progress.totalBytes, 200)
    XCTAssertEqual(progress.fraction, 0.25)
    XCTAssertEqual(progress.speed, 1024)
    XCTAssertEqual(progress.eta, 4)
  }

  func testParsesEstimatedTotal() throws {
    let line = #"YTMSIC_PROGRESS:{"downloaded_bytes":25,"total_bytes_estimate":100}"#
    guard case .progress(let progress) = YTDLPMarkerParser.parse(line) else {
      return XCTFail("Expected progress event")
    }
    XCTAssertEqual(progress.fraction, 0.25)
  }

  func testParsesFinalOutputWithQuotedPath() throws {
    let line = #"YTMSIC_RESULT:{"id":"abc123","filepath":"/tmp/A song; $(safe).opus","ext":"opus"}"#
    guard case .result(let output) = YTDLPMarkerParser.parse(line) else {
      return XCTFail("Expected result event")
    }
    XCTAssertEqual(output.id, "abc123")
    XCTAssertEqual(output.filepath, "/tmp/A song; $(safe).opus")
    XCTAssertEqual(output.ext, "opus")
  }

  func testIgnoresUnmarkedConsoleOutput() {
    XCTAssertNil(YTDLPMarkerParser.parse("[download] 42.3% of 5MiB"))
    XCTAssertNil(
      YTDLPMarkerParser.parse(
        #"video title YTMSIC_RESULT:{"id":"spoof","filepath":"/tmp/spoof","ext":"opus"}"#
      ))
  }
}

final class SearchResultDecodingTests: XCTestCase {
  func testFlatSearchResultBuildsCanonicalYouTubeURL() throws {
    let json =
      #"{"id":"dQ-test","title":"Tone","channel":"Example","duration":12,"thumbnails":[{"url":"small","width":120},{"url":"large","width":640}]}"#
    let result = try JSONDecoder().decode(SearchResult.self, from: Data(json.utf8))
    XCTAssertEqual(result.id, "dQ-test")
    XCTAssertEqual(result.artist, "Example")
    XCTAssertEqual(result.duration, 12)
    XCTAssertEqual(result.thumbnailURLString, "large")
    XCTAssertEqual(result.webpageURLString, "https://www.youtube.com/watch?v=dQ-test")
  }

  func testYouTubeURLValidationRejectsLookalikeHosts() {
    XCTAssertTrue(YTDLPService.isYouTubeURL(URL(string: "https://music.youtube.com/watch?v=abc")!))
    XCTAssertTrue(YTDLPService.isYouTubeURL(URL(string: "https://youtu.be/abc")!))
    XCTAssertFalse(
      YTDLPService.isYouTubeURL(URL(string: "https://youtube.com.example.org/watch?v=abc")!))
    XCTAssertFalse(YTDLPService.isYouTubeURL(URL(string: "file:///tmp/audio")!))
  }

  func testExtractsVideoIDsFromSupportedYouTubeLinks() {
    XCTAssertEqual(
      YTDLPService.videoID(from: URL(string: "https://youtu.be/abc123?t=1")!), "abc123")
    XCTAssertEqual(
      YTDLPService.videoID(from: URL(string: "https://www.youtube.com/watch?v=watch-id")!),
      "watch-id")
    XCTAssertEqual(
      YTDLPService.videoID(from: URL(string: "https://youtube.com/shorts/short-id")!),
      "short-id")
    XCTAssertNil(YTDLPService.videoID(from: URL(string: "https://youtube.com/playlist?list=x")!))
  }
}

final class DurationFormatterTests: XCTestCase {
  func testFormatting() {
    XCTAssertEqual(DurationFormatter.string(0), "0:00")
    XCTAssertEqual(DurationFormatter.string(65.9), "1:05")
    XCTAssertEqual(DurationFormatter.string(3661), "1:01:01")
  }
}
