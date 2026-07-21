import Foundation

enum DownloadIntent: String {
  case playOnce
  case keep

  var title: String {
    switch self {
    case .playOnce: "Play once"
    case .keep: "Keep in Library"
    }
  }
}

enum DownloadPhase: String, Codable {
  case queued
  case preparing
  case downloading
  case converting
  case importing
  case completed
  case failed
  case cancelled

  var title: String {
    switch self {
    case .queued: "Queued"
    case .preparing: "Preparing"
    case .downloading: "Downloading"
    case .converting: "Converting"
    case .importing: "Adding to library"
    case .completed: "Complete"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }

  var isActive: Bool {
    switch self {
    case .queued, .preparing, .downloading, .converting, .importing: true
    case .completed, .failed, .cancelled: false
    }
  }
}

struct DownloadJob: Identifiable {
  let id: UUID
  let result: SearchResult
  var phase: DownloadPhase
  var progress: Double?
  var downloadedBytes: Int64?
  var totalBytes: Int64?
  var speed: Double?
  var eta: Double?
  var statusMessage: String?
  var errorMessage: String?
  var createdAt: Date
  var completedAt: Date?
  let intent: DownloadIntent

  init(result: SearchResult, intent: DownloadIntent) {
    id = UUID()
    self.result = result
    phase = .queued
    progress = nil
    downloadedBytes = nil
    totalBytes = nil
    speed = nil
    eta = nil
    statusMessage = nil
    errorMessage = nil
    createdAt = Date()
    completedAt = nil
    self.intent = intent
  }
}
