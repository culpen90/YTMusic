import Foundation

enum AudioFormat: String, CaseIterable, Codable, Identifiable {
  case best
  case alac
  case m4a
  case mp3

  var id: String { rawValue }

  var title: String {
    switch self {
    case .best: "Best available"
    case .alac: "ALAC"
    case .m4a: "M4A / AAC"
    case .mp3: "MP3"
    }
  }

  var detail: String {
    switch self {
    case .best:
      "Keeps the highest-quality source audio without another lossy conversion."
    case .alac:
      "Lossless conversion preserves the decoded source, but uses much more space."
    case .m4a:
      "Smaller and broadly compatible, with one additional lossy conversion."
    case .mp3:
      "Most compatible, with one additional lossy conversion."
    }
  }

  var ytDLPArguments: [String] {
    switch self {
    case .best:
      ["--audio-format", "best"]
    case .alac:
      ["--audio-format", "alac", "--audio-quality", "0"]
    case .m4a:
      ["--audio-format", "m4a", "--audio-quality", "0"]
    case .mp3:
      ["--audio-format", "mp3", "--audio-quality", "0"]
    }
  }
}
