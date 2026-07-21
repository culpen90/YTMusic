import Foundation

struct DownloadProgress: Decodable, Equatable, Sendable {
  let status: String?
  let downloadedBytes: Int64?
  let totalBytes: Int64?
  let totalBytesEstimate: Int64?
  let speed: Double?
  let eta: Double?
  let filename: String?

  private enum CodingKeys: String, CodingKey {
    case status
    case downloadedBytes = "downloaded_bytes"
    case totalBytes = "total_bytes"
    case totalBytesEstimate = "total_bytes_estimate"
    case speed, eta, filename
  }

  var fraction: Double? {
    guard let downloadedBytes else { return nil }
    let total = totalBytes ?? totalBytesEstimate
    guard let total, total > 0 else { return nil }
    return min(max(Double(downloadedBytes) / Double(total), 0), 1)
  }
}

struct DownloadOutput: Decodable, Equatable, Sendable {
  let id: String
  let filepath: String
  let ext: String?
}

enum YTDLPEvent: Sendable {
  case progress(DownloadProgress)
  case postprocessing(DownloadProgress?)
  case metadata(SearchResult)
  case result(DownloadOutput)
}

enum YTDLPMarkerParser {
  static let progressPrefix = "YTMSIC_PROGRESS:"
  static let postprocessPrefix = "YTMSIC_POSTPROCESS:"
  static let metadataPrefix = "YTMSIC_META:"
  static let resultPrefix = "YTMSIC_RESULT:"

  static func parse(_ line: String, decoder: JSONDecoder = JSONDecoder()) -> YTDLPEvent? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

    if let payload = payload(after: progressPrefix, in: trimmed),
      let data = payload.data(using: .utf8),
      let progress = try? decoder.decode(DownloadProgress.self, from: data)
    {
      return .progress(progress)
    }

    if let payload = payload(after: postprocessPrefix, in: trimmed) {
      let progress = payload.data(using: .utf8).flatMap {
        try? decoder.decode(DownloadProgress.self, from: $0)
      }
      return .postprocessing(progress)
    }

    if let payload = payload(after: metadataPrefix, in: trimmed),
      let data = payload.data(using: .utf8),
      let metadata = try? decoder.decode(SearchResult.self, from: data)
    {
      return .metadata(metadata)
    }

    if let payload = payload(after: resultPrefix, in: trimmed),
      let data = payload.data(using: .utf8),
      let output = try? decoder.decode(DownloadOutput.self, from: data)
    {
      return .result(output)
    }

    return nil
  }

  private static func payload(after prefix: String, in line: String) -> String? {
    guard line.hasPrefix(prefix) else { return nil }
    return String(line.dropFirst(prefix.count))
  }
}
