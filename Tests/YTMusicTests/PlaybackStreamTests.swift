import XCTest

@testable import YTMusic

final class PlaybackStreamTests: XCTestCase {
  func testParsesAllowedStreamURLAndUserAgent() throws {
    let stream = try YTDLPService.parsePlaybackStream(
      #"{"url":"https://rr1.googlevideo.com/audio.m4a?token=abc","http_headers":{"User-Agent":"Playback Test","Accept":"*/*"}}"#
    )

    XCTAssertEqual(
      stream.audioURL.absoluteString, "https://rr1.googlevideo.com/audio.m4a?token=abc")
    XCTAssertEqual(stream.userAgent, "Playback Test")
  }

  func testRejectsUnsafeOrAmbiguousStreamOutput() {
    let invalidOutputs = [
      "",
      "not a URL",
      #"{"url":"http://rr1.googlevideo.com/audio.m4a","http_headers":{}}"#,
      #"{"url":"file:///tmp/audio.m4a","http_headers":{}}"#,
      #"{"url":"https://user:secret@rr1.googlevideo.com/audio.m4a","http_headers":{}}"#,
      #"{"url":"https://rr1.googlevideo.com/audio.m4a#fragment","http_headers":{}}"#,
      #"{"url":"https://127.0.0.1/audio.m4a","http_headers":{}}"#,
      #"{"url":"https://media.example.test/audio.m4a","http_headers":{}}"#,
      #"{"url":"https://rr1.googlevideo.com:444/audio.m4a","http_headers":{}}"#,
      #"{"url":"https://rr1.googlevideo.com/audio.m4a","http_headers":{"User-Agent":"bad\r\nInjected: value"}}"#,
      #"{"url":"https://one.googlevideo.com/audio.m4a","http_headers":{}}"#
        + "\n"
        + #"{"url":"https://two.googlevideo.com/audio.m4a","http_headers":{}}"#,
    ]

    for output in invalidOutputs {
      XCTAssertThrowsError(try YTDLPService.parsePlaybackStream(output), output)
    }
  }

  func testPlaybackArgumentsSelectStereoAACWithoutDownloading() {
    let arguments = YTDLPService.playbackStreamArguments(
      for: URL(string: "https://www.youtube.com/watch?v=stream-test")!,
      denoURL: URL(fileURLWithPath: "/opt/homebrew/bin/deno"))

    XCTAssertTrue(arguments.contains("--skip-download"))
    XCTAssertTrue(arguments.contains("--print"))
    XCTAssertFalse(arguments.contains("--extract-audio"))
    XCTAssertFalse(arguments.contains("--write-thumbnail"))
    XCTAssertFalse(arguments.contains("--embed-metadata"))
    let formatChoices = YTDLPService.playbackFormatSelector.split(separator: "/")
    XCTAssertTrue(formatChoices.allSatisfy { $0.contains("audio_channels<=2") })
    XCTAssertTrue(formatChoices.allSatisfy { $0.contains("acodec^=mp4a") })
    XCTAssertFalse(YTDLPService.playbackFormatSelector.contains("bestaudio/best"))
  }

  func testPlaybackTrackKeepsExpiringStreamSeparateFromPersistentTrackModel() {
    let metadata = SearchResult(
      id: "stream-test",
      title: "Stream Test",
      artist: "Example",
      duration: 60,
      webpageURLString: "https://www.youtube.com/watch?v=stream-test",
      thumbnailURLString: "https://images.example.test/stream-test.jpg")
    let stream = PlaybackStream(
      audioURL: URL(string: "https://rr1.googlevideo.com/stream-test.m4a?token=abc")!,
      userAgent: "Playback Test")

    let track = PlaybackTrack(stream: metadata, resolvedStream: stream)

    XCTAssertTrue(track.isStreaming)
    XCTAssertNil(track.localTrack)
    XCTAssertNil(track.localFilePath)
    XCTAssertEqual(track.resolvedStream, stream)
    XCTAssertEqual(track.audioURL, stream.audioURL)
    XCTAssertEqual(track.title, metadata.title)
  }
}
