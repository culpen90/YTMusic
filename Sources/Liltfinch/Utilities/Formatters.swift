import Foundation

enum DurationFormatter {
  static func string(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remaining = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remaining)
    }
    return String(format: "%d:%02d", minutes, remaining)
  }
}
