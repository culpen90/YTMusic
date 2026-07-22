import Darwin
import Foundation

struct CommandResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

enum CommandOutputStream: Sendable, Equatable {
  case stdout
  case stderr
}

enum SubprocessError: LocalizedError {
  case couldNotLaunch(String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .couldNotLaunch(let reason): "Could not launch the downloader: \(reason)"
    case .cancelled: "The operation was cancelled."
    }
  }
}

final class SubprocessRunner {
  typealias LineHandler = @Sendable (String, CommandOutputStream) -> Void

  func run(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    environment: [String: String]? = nil,
    onLine: @escaping LineHandler = { _, _ in }
  ) async throws -> CommandResult {
    try Task.checkCancellation()
    let process = Process()
    let launcherURL = ProcessGroupLauncher.executableURL
    process.executableURL = launcherURL ?? executableURL
    process.arguments =
      launcherURL.map { _ in
        [ProcessGroupLauncher.marker, executableURL.path] + arguments
      } ?? arguments
    process.currentDirectoryURL = currentDirectoryURL
    if let environment {
      process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new
      }
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let collector = ProcessOutputCollector(onLine: onLine)
    let cancellation = ProcessCancellationFlag()
    let readers = DispatchGroup()
    readers.enter()
    readers.enter()

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
          cancellation.markTerminated()
          readers.notify(queue: .global(qos: .utility)) {
            collector.flush()
            let output = collector.snapshot()

            if cancellation.isCancelled {
              continuation.resume(throwing: SubprocessError.cancelled)
            } else {
              continuation.resume(
                returning: CommandResult(
                  exitCode: process.terminationStatus,
                  stdout: output.stdout,
                  stderr: output.stderr
                ))
            }
          }
        }

        do {
          try process.run()
          let processID = process.processIdentifier
          let ownsProcessGroup = launcherURL != nil || setpgid(processID, processID) == 0
          cancellation.attach(processID: processID, ownsProcessGroup: ownsProcessGroup)

          Self.read(
            stdoutPipe.fileHandleForReading,
            stream: .stdout,
            into: collector,
            group: readers
          )
          Self.read(
            stderrPipe.fileHandleForReading,
            stream: .stderr,
            into: collector,
            group: readers
          )

          if cancellation.isCancelled {
            cancellation.signal(SIGINT)
          }
        } catch {
          process.terminationHandler = nil
          readers.leave()
          readers.leave()
          if cancellation.isCancelled {
            continuation.resume(throwing: SubprocessError.cancelled)
          } else {
            continuation.resume(
              throwing: SubprocessError.couldNotLaunch(error.localizedDescription))
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
      cancellation.signal(SIGINT)
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
        cancellation.signal(SIGTERM)
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
        cancellation.signal(SIGKILL)
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
        if cancellation.isCancelled {
          try? stdoutPipe.fileHandleForReading.close()
          try? stderrPipe.fileHandleForReading.close()
        }
      }
    }
  }

  private static func read(
    _ handle: FileHandle,
    stream: ProcessOutputCollector.Stream,
    into collector: ProcessOutputCollector,
    group: DispatchGroup
  ) {
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      do {
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
          collector.append(data, stream: stream)
        }
      } catch {
        // Closing the handle is the final cancellation fallback.
      }
    }
  }
}

private final class ProcessCancellationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  private var processID: pid_t?
  private var ownsProcessGroup = false
  private var hasTerminated = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }

  func attach(processID: pid_t, ownsProcessGroup: Bool) {
    lock.lock()
    self.processID = processID
    self.ownsProcessGroup = ownsProcessGroup
    lock.unlock()
  }

  func signal(_ signal: Int32) {
    lock.lock()
    let processID = processID
    let ownsProcessGroup = ownsProcessGroup
    let hasTerminated = hasTerminated
    lock.unlock()
    guard !hasTerminated || ownsProcessGroup, let processID, processID > 0 else { return }
    let result = kill(ownsProcessGroup ? -processID : processID, signal)
    if result != 0, ownsProcessGroup, !hasTerminated {
      _ = kill(processID, signal)
    }
  }

  func markTerminated() {
    lock.lock()
    hasTerminated = true
    lock.unlock()
  }
}

private final class ProcessOutputCollector: @unchecked Sendable {
  typealias Stream = CommandOutputStream

  private static let outputLimit = 8 * 1024 * 1024
  private static let lineLimit = 1024 * 1024

  private let lock = NSLock()
  private var stdoutData = Data()
  private var stderrData = Data()
  private var stdoutLineBuffer = Data()
  private var stderrLineBuffer = Data()
  private var stdoutIsDroppingLine = false
  private var stderrIsDroppingLine = false
  private let onLine: @Sendable (String, CommandOutputStream) -> Void

  init(onLine: @escaping @Sendable (String, CommandOutputStream) -> Void) {
    self.onLine = onLine
  }

  func append(_ data: Data, stream: Stream) {
    guard !data.isEmpty else { return }
    lock.lock()
    switch stream {
    case .stdout:
      Self.appendPrefix(data, to: &stdoutData)
      Self.consumeLines(
        data,
        buffer: &stdoutLineBuffer,
        isDropping: &stdoutIsDroppingLine,
        stream: .stdout,
        onLine: onLine
      )
    case .stderr:
      Self.appendSuffix(data, to: &stderrData)
      Self.consumeLines(
        data,
        buffer: &stderrLineBuffer,
        isDropping: &stderrIsDroppingLine,
        stream: .stderr,
        onLine: onLine
      )
    }
    lock.unlock()
  }

  func flush() {
    lock.lock()
    defer { lock.unlock() }
    if !stdoutIsDroppingLine {
      Self.emitRemainder(from: &stdoutLineBuffer, stream: .stdout, onLine: onLine)
    }
    if !stderrIsDroppingLine {
      Self.emitRemainder(from: &stderrLineBuffer, stream: .stderr, onLine: onLine)
    }
    stdoutIsDroppingLine = false
    stderrIsDroppingLine = false
  }

  func snapshot() -> (stdout: String, stderr: String) {
    lock.lock()
    defer { lock.unlock() }
    return (
      String(decoding: stdoutData, as: UTF8.self),
      String(decoding: stderrData, as: UTF8.self)
    )
  }

  private static func appendPrefix(_ data: Data, to output: inout Data) {
    let remaining = outputLimit - output.count
    guard remaining > 0 else { return }
    output.append(data.prefix(remaining))
  }

  private static func appendSuffix(_ data: Data, to output: inout Data) {
    output.append(data)
    if output.count > outputLimit {
      output = Data(output.suffix(outputLimit / 2))
    }
  }

  private static func consumeLines(
    _ data: Data,
    buffer: inout Data,
    isDropping: inout Bool,
    stream: CommandOutputStream,
    onLine: @Sendable (String, CommandOutputStream) -> Void
  ) {
    var start = data.startIndex
    while start < data.endIndex {
      if let newline = data[start...].firstIndex(of: 0x0A) {
        if !isDropping {
          let segment = data[start..<newline]
          if buffer.count + segment.count <= lineLimit {
            buffer.append(segment)
            emitRemainder(from: &buffer, stream: stream, onLine: onLine)
          } else {
            buffer.removeAll(keepingCapacity: false)
          }
        }
        isDropping = false
        start = data.index(after: newline)
      } else {
        if !isDropping {
          let segment = data[start...]
          if buffer.count + segment.count <= lineLimit {
            buffer.append(segment)
          } else {
            buffer.removeAll(keepingCapacity: false)
            isDropping = true
          }
        }
        break
      }
    }
  }

  private static func emitRemainder(
    from buffer: inout Data,
    stream: CommandOutputStream,
    onLine: @Sendable (String, CommandOutputStream) -> Void
  ) {
    guard !buffer.isEmpty else { return }
    let line = String(decoding: buffer, as: UTF8.self)
    buffer.removeAll(keepingCapacity: false)
    if !line.isEmpty { onLine(line, stream) }
  }
}
