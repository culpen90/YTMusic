import SwiftUI

struct DownloadsView: View {
  let model: AppModel

  private var active: [DownloadJob] { model.downloads.jobs.filter { $0.phase.isActive } }
  private var history: [DownloadJob] {
    model.downloads.jobs.filter { !$0.phase.isActive }.reversed()
  }

  var body: some View {
    Group {
      if model.downloads.jobs.isEmpty {
        ContentUnavailableView {
          Label("No Downloads Yet", systemImage: "arrow.down.circle")
        } description: {
          Text("Songs you download for offline listening appear here and remain in your library.")
        } actions: {
          Button("Discover Music") { model.selection = .discover }
            .buttonStyle(.borderedProminent)
        }
      } else {
        List {
          if !active.isEmpty {
            Section("Active and Queued") {
              ForEach(active) { job in DownloadRow(model: model, job: job) }
            }
          }
          if !history.isEmpty {
            Section("History") {
              ForEach(history) { job in DownloadRow(model: model, job: job) }
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .navigationTitle("Downloads")
    .toolbar {
      if !history.isEmpty {
        Button("Clear Finished") { model.downloads.clearFinished() }
      }
    }
  }
}

private struct DownloadRow: View {
  let model: AppModel
  let job: DownloadJob

  var body: some View {
    HStack(spacing: 13) {
      ArtworkView(remoteURL: job.result.thumbnailURL, cornerRadius: 9)
        .frame(width: 58, height: 58)
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(job.result.title).font(.headline).lineLimit(1)
          Text(job.intent.title)
            .font(.caption2.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
              job.intent == .playOnce ? Color.purple.opacity(0.14) : Color.blue.opacity(0.14),
              in: Capsule())
        }
        Text(job.errorMessage ?? detailText)
          .font(.caption)
          .foregroundStyle(job.phase == .failed ? .red : .secondary)
          .lineLimit(2)
        if job.phase == .downloading {
          if let progress = job.progress {
            ProgressView(value: progress)
          } else {
            ProgressView()
          }
        }
      }
      Spacer()
      if job.phase.isActive {
        Button {
          model.downloads.cancel(job.id)
        } label: {
          Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .help("Cancel and delete temporary files")
      } else if job.phase == .failed || job.phase == .cancelled {
        Button("Retry") { model.retry(job) }
          .buttonStyle(.bordered)
      } else if job.phase == .completed {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)
      }
    }
    .padding(.vertical, 5)
  }

  private var detailText: String {
    var parts = [job.phase.title]
    if let progress = job.progress { parts.append("\(Int(progress * 100))%") }
    if let speed = job.speed, speed > 0 {
      parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
    }
    if let eta = job.eta, eta > 0 { parts.append("\(DurationFormatter.string(eta)) left") }
    if job.intent == .playOnce && job.phase == .completed {
      parts.append("file will be deleted after playback")
    }
    return parts.joined(separator: " • ")
  }
}
