import Foundation

struct ToolchainStatus: Equatable {
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
    let customDownloader = defaults.string(forKey: "downloaderPath")
    let customFFmpeg = defaults.string(forKey: "ffmpegPath")

    let downloader = firstExecutable(
      customDownloader.map(URL.init(fileURLWithPath:)),
      named: ["yt-dlp"]
    )
    let ffmpeg = firstExecutable(
      customFFmpeg.map(URL.init(fileURLWithPath:)),
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

  private static func firstExecutable(_ preferred: URL?, named names: [String]) -> URL? {
    let fileManager = FileManager.default
    if let preferred, fileManager.isExecutableFile(atPath: preferred.path) {
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
        if fileManager.isExecutableFile(atPath: candidate.path) {
          return candidate.standardizedFileURL
        }
      }
    }
    return nil
  }
}
