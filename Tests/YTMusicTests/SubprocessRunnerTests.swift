import XCTest

@testable import YTMusic

final class SubprocessRunnerTests: XCTestCase {
  func testArgumentsArePassedLiterallyWithoutShellEvaluation() async throws {
    let hostileLookingValue = #"$(touch /tmp/should-never-exist); `whoami`; *.opus"#
    let result = try await SubprocessRunner().run(
      executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
      arguments: ["%s", hostileLookingValue]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, hostileLookingValue)
  }

  func testCancellationInterruptsLongRunningProcess() async throws {
    let task = Task {
      try await SubprocessRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["30"]
      )
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch SubprocessError.cancelled {
      // Expected.
    } catch is CancellationError {
      // Cancellation before launch is also valid.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testShortLivedProcessOutputIsFullyDrainedBeforeReturn() async throws {
    for index in 0..<30 {
      let expected = "final-result-\(index)\n"
      let result = try await SubprocessRunner().run(
        executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
        arguments: [expected]
      )
      XCTAssertEqual(result.stdout, expected)
      XCTAssertEqual(result.exitCode, 0)
    }
  }

  func testOutputCollectionIsBoundedForLargeUnbrokenStreams() async throws {
    let result = try await SubprocessRunner().run(
      executableURL: URL(fileURLWithPath: "/usr/bin/head"),
      arguments: ["-c", "12582912", "/dev/zero"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout.utf8.count, 8 * 1024 * 1024)
  }
}
