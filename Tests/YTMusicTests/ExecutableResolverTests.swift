import XCTest

@testable import YTMusic

final class ExecutableResolverTests: XCTestCase {
  func testBlankCustomPathUsesAutomaticDetection() {
    XCTAssertNil(ExecutableResolver.executableURL(forCustomPath: nil))
    XCTAssertNil(ExecutableResolver.executableURL(forCustomPath: ""))
    XCTAssertNil(ExecutableResolver.executableURL(forCustomPath: "  \n"))
  }

  func testCustomPathMustBeAnExecutableRegularFile() {
    XCTAssertNil(
      ExecutableResolver.executableURL(
        forCustomPath: FileManager.default.temporaryDirectory.path))
    XCTAssertEqual(
      ExecutableResolver.executableURL(forCustomPath: "/usr/bin/true")?.path,
      "/usr/bin/true"
    )
  }

  func testExecutableSymlinkIsAccepted() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let symlink = directory.appendingPathComponent("tool")
    try FileManager.default.createSymbolicLink(
      at: symlink,
      withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
    )

    XCTAssertEqual(
      ExecutableResolver.executableURL(forCustomPath: symlink.path)?.path,
      symlink.path
    )
  }
}
