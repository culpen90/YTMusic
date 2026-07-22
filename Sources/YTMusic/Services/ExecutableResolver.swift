import Foundation

struct ToolchainStatus: Equatable, Sendable {
  var downloaderURL: URL?
  var ffmpegURL: URL?
  var denoURL: URL?
  var downloaderVersion: String?
  var ffmpegVersion: String?

  var isReady: Bool {
    downloaderURL != nil && ffmpegURL != nil
      && downloaderVersion != nil && ffmpegVersion != nil
  }
}

enum ExecutableResolver {
  static func detect() -> ToolchainStatus {
    let defaults = UserDefaults.standard
    let customDownloader = executableURL(forCustomPath: defaults.string(forKey: "downloaderPath"))
    let customFFmpeg = executableURL(forCustomPath: defaults.string(forKey: "ffmpegPath"))

    let downloader = firstExecutable(
      customDownloader,
      named: ["yt-dlp"]
    )
    let ffmpeg = firstExecutable(
      customFFmpeg,
      named: ["ffmpeg"]
    )
    let deno = firstExecutable(nil, named: ["deno"])

    return ToolchainStatus(
      downloaderURL: downloader,
      ffmpegURL: ffmpeg,
      denoURL: deno,
      downloaderVersion: nil,
      ffmpegVersion: nil
    )
  }

  static func executableURL(forCustomPath path: String?) -> URL? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
    else {
      return nil
    }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return isExecutableRegularFile(url) ? url : nil
  }

  private static func firstExecutable(_ preferred: URL?, named names: [String]) -> URL? {
    if let preferred, isExecutableRegularFile(preferred) {
      return preferred
    }

    var directories = [
      Bundle.main.resourceURL?.appendingPathComponent("bin"),
      URL(fileURLWithPath: "/opt/homebrew/bin"),
      URL(fileURLWithPath: "/usr/local/bin"),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"),
    ].compactMap { $0 }

    let pathDirectories =
      ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0)) } ?? []
    directories.append(contentsOf: pathDirectories)

    for directory in directories {
      for name in names {
        let candidate = directory.appendingPathComponent(name)
        if isExecutableRegularFile(candidate) {
          return candidate.standardizedFileURL
        }
      }
    }
    return nil
  }

  private static func isExecutableRegularFile(_ url: URL) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: url.path),
      let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
    else {
      return false
    }
    return values.isRegularFile == true
  }
}
