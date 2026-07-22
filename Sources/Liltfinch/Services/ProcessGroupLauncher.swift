import Darwin
import Foundation

enum ProcessGroupLauncher {
  static let marker = "--liltfinch-process-group-launcher"

  static var executableURL: URL? {
    guard let url = Bundle.main.executableURL, url.lastPathComponent == "Liltfinch" else {
      return nil
    }
    return url
  }

  static func launchIfRequested() {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3, arguments[1] == marker else { return }

    let executablePath = arguments[2]
    let targetArguments = Array(arguments.dropFirst(3))
    let processID = getpid()
    guard getpgrp() == processID || setpgid(0, 0) == 0 else {
      writeFailure(
        "Liltfinch could not create a process group: \(String(cString: strerror(errno)))")
    }

    var pointers: [UnsafeMutablePointer<CChar>?] =
      ([executablePath] + targetArguments).map { strdup($0) }
    pointers.append(nil)
    defer {
      for pointer in pointers { free(pointer) }
    }

    _ = executablePath.withCString { path in
      pointers.withUnsafeMutableBufferPointer { buffer in
        execv(path, buffer.baseAddress)
      }
    }
    writeFailure(
      "Liltfinch could not launch \(executablePath): \(String(cString: strerror(errno)))")
  }

  private static func writeFailure(_ message: String) -> Never {
    if let data = (message + "\n").data(using: .utf8) {
      try? FileHandle.standardError.write(contentsOf: data)
    }
    _exit(127)
  }
}
