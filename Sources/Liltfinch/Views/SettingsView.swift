import AppKit
import SwiftUI

struct SettingsView: View {
  let model: AppModel
  @AppStorage("audioFormat") private var audioFormat = AudioFormat.best.rawValue
  @AppStorage("downloaderPath") private var downloaderPath = ""
  @AppStorage("ffmpegPath") private var ffmpegPath = ""
  @State private var pathRefreshTask: Task<Void, Never>?

  var body: some View {
    TabView {
      general
        .tabItem { Label("General", systemImage: "slider.horizontal.3") }
      tools
        .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
      storage
        .tabItem { Label("Storage", systemImage: "internaldrive") }
    }
    .scenePadding()
    .frame(width: 590, height: 410)
  }

  private var general: some View {
    Form {
      Section("Downloaded Audio Format") {
        Picker("Format", selection: $audioFormat) {
          ForEach(AudioFormat.allCases) { format in
            Text(format.title).tag(format.rawValue)
          }
        }
        if let format = AudioFormat(rawValue: audioFormat) {
          Text(format.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("Play Once streams a stereo AAC source directly for faster startup.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Playback Storage") {
        Label(
          "Play Once streams audio without creating an app-managed song file.",
          systemImage: "dot.radiowaves.left.and.right")
        Label(
          "Download is the only action that keeps audio in the Library folder.",
          systemImage: "arrow.down.circle")
        Label("Playlists retain URLs and display metadata only.", systemImage: "link.circle")
      }

      Section("About Liltfinch") {
        LabeledContent("Version", value: appVersion)
      }

      Section {
        Text(
          "Only download media you own or have permission to save. Liltfinch does not bypass DRM, private access, or platform restrictions."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "LiltfinchVersion") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development"
  }

  private var tools: some View {
    Form {
      Section("Status") {
        ToolStatusRow(
          name: "yt-dlp",
          path: model.toolchain.status.downloaderURL?.path,
          version: model.toolchain.status.downloaderVersion,
          ready: model.toolchain.status.downloaderVersion != nil
        )
        ToolStatusRow(
          name: "FFmpeg",
          path: model.toolchain.status.ffmpegURL?.path,
          version: model.toolchain.status.ffmpegVersion,
          ready: model.toolchain.status.ffmpegVersion != nil
        )
      }

      Section("Custom Paths") {
        PathPickerRow(title: "Downloader", path: $downloaderPath)
        PathPickerRow(title: "FFmpeg", path: $ffmpegPath)
      }

      Section {
        HStack {
          Button("Detect Again") {
            model.toolchain.refresh()
          }
          .disabled(model.toolchain.isChecking)
          Button("Install with Homebrew") {
            model.toolchain.installWithHomebrew()
          }
          .disabled(model.toolchain.isInstalling)
          Spacer()
          if model.toolchain.isChecking || model.toolchain.isInstalling {
            ProgressView().controlSize(.small)
          }
        }
        if let error = model.toolchain.errorMessage {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      }

      if !model.toolchain.setupLog.isEmpty {
        Section("Homebrew Output") {
          ScrollView {
            Text(model.toolchain.setupLog)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 105)
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: downloaderPath) { _, _ in scheduleToolRefresh() }
    .onChange(of: ffmpegPath) { _, _ in scheduleToolRefresh() }
    .onDisappear { pathRefreshTask?.cancel() }
  }

  private var storage: some View {
    Form {
      Section("Downloaded Library") {
        LabeledContent("Songs", value: "\(model.library.tracks.count)")
        LabeledContent(
          "Disk usage",
          value: ByteCountFormatter.string(
            fromByteCount: model.library.totalSize, countStyle: .file))
        LabeledContent("Location", value: model.library.mediaDirectory.path)
          .lineLimit(2)
        Button("Show in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([model.library.mediaDirectory])
        }
      }

      Section("Transient Data") {
        Text(
          "Play Once does not save audio. Incomplete download staging is swept every time the app launches or quits."
        )
        .foregroundStyle(.secondary)
        Button("Clean Temporary Files Now") {
          if model.player.currentTrack?.localTrack?.storage == .temporary {
            model.player.stopForReplacement()
          }
          model.library.cleanupAllTemporaryFiles()
        }
        .disabled(model.downloads.activeCount > 0)
      }
    }
    .formStyle(.grouped)
  }

  private func scheduleToolRefresh() {
    pathRefreshTask?.cancel()
    pathRefreshTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled else { return }
      model.toolchain.refresh()
    }
  }
}

private struct ToolStatusRow: View {
  let name: String
  let path: String?
  let version: String?
  let ready: Bool

  var body: some View {
    HStack(alignment: .top) {
      Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(ready ? .green : .red)
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.headline)
        Text(version ?? "Not validated")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        if let path {
          Text(path)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
  }
}

private struct PathPickerRow: View {
  let title: String
  @Binding var path: String

  var body: some View {
    HStack {
      TextField(title, text: $path, prompt: Text("Auto-detect"))
        .textFieldStyle(.roundedBorder)
      Button("Choose…") {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
      }
      Button {
        path = ""
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .help("Use automatic detection")
    }
  }
}
