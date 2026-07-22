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
    XCTAssertNil(stream.timeline)
  }

  func testBuildsSongTimelineFromValidatedNonMusicSections() throws {
    let stream = try YTDLPService.parsePlaybackStream(
      #"{"url":"https://rr1.googlevideo.com/audio.m4a","http_headers":{},"duration":421,"sponsorblock_chapters":[{"start_time":0,"end_time":94,"category":"music_offtopic","type":"skip"},{"start_time":181.4,"end_time":215.4,"category":"music_offtopic","type":"skip"},{"start_time":234,"end_time":241,"category":"music_offtopic","type":"skip"},{"start_time":301.9,"end_time":328.9,"category":"music_offtopic","type":"skip"},{"start_time":393,"end_time":421,"category":"music_offtopic","type":"skip"}]}"#
    )

    let timeline = try XCTUnwrap(stream.timeline)
    XCTAssertEqual(timeline.duration, 231, accuracy: 0.001)
    XCTAssertEqual(timeline.sourceStartTime, 94, accuracy: 0.001)
    XCTAssertEqual(timeline.sourceEndTime, 393, accuracy: 0.001)
    XCTAssertEqual(timeline.internalBoundaryTimes, [181.4, 234, 301.9])
    XCTAssertEqual(timeline.sourceTime(forPlaybackTime: 0), 94, accuracy: 0.001)
    XCTAssertEqual(timeline.sourceTime(forPlaybackTime: 87.4), 215.4, accuracy: 0.001)
    XCTAssertEqual(timeline.sourceTime(forPlaybackTime: 231), 393, accuracy: 0.001)
    XCTAssertEqual(timeline.playbackTime(forSourceTime: 215.4), 87.4, accuracy: 0.001)
    XCTAssertEqual(timeline.playbackTime(forSourceTime: 393), 231, accuracy: 0.001)
  }

  func testUsesExtractedDurationWhenNoNonMusicSectionsExist() throws {
    let stream = try YTDLPService.parsePlaybackStream(
      #"{"url":"https://rr1.googlevideo.com/audio.m4a","http_headers":{},"duration":218,"sponsorblock_chapters":[]}"#
    )

    let timeline = try XCTUnwrap(stream.timeline)
    XCTAssertEqual(timeline.duration, 218, accuracy: 0.001)
    XCTAssertEqual(timeline.sourceStartTime, 0, accuracy: 0.001)
    XCTAssertEqual(timeline.sourceEndTime, 218, accuracy: 0.001)
    XCTAssertTrue(timeline.internalBoundaryTimes.isEmpty)
  }

  func testIgnoresUntrustedOrUnusableNonMusicSections() throws {
    let stream = try YTDLPService.parsePlaybackStream(
      #"{"url":"https://rr1.googlevideo.com/audio.m4a","http_headers":{},"duration":180,"sponsorblock_chapters":[{"start_time":20,"end_time":40,"category":"sponsor","type":"skip"},{"start_time":40,"end_time":30,"category":"music_offtopic","type":"skip"},{"start_time":"bad","end_time":180,"category":"music_offtopic","type":"skip"},{"start_time":0,"end_time":180,"category":"music_offtopic","type":"skip"}]}"#
    )

    let timeline = try XCTUnwrap(stream.timeline)
    XCTAssertEqual(timeline.duration, 180, accuracy: 0.001)
    XCTAssertTrue(timeline.excludedSegments.isEmpty)
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

    XCTAssertThrowsError(
      try YTDLPService.parsePlaybackStream(
        #"{"id":"wrong-id","url":"https://rr1.googlevideo.com/audio.m4a","http_headers":{},"duration":180}"#,
        expectedVideoID: "expected-id"
      ))
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
    let sponsorBlockIndex = try? XCTUnwrap(arguments.firstIndex(of: "--sponsorblock-mark"))
    XCTAssertEqual(sponsorBlockIndex.map { arguments[$0 + 1] }, "music_offtopic")
    XCTAssertTrue(arguments.contains { $0.contains("sponsorblock_chapters") })
    let plainArguments = YTDLPService.playbackStreamArguments(
      for: URL(string: "https://www.youtube.com/watch?v=stream-test")!,
      denoURL: nil,
      includeMusicSections: false
    )
    XCTAssertFalse(plainArguments.contains("--sponsorblock-mark"))
    XCTAssertFalse(plainArguments.contains { $0.contains("sponsorblock_chapters") })
    XCTAssertTrue(plainArguments.contains { $0.contains(#""duration""#) })
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
