import SwiftUI

private struct PlaylistSheetDestination: Identifiable {
  let id = UUID()
}

struct PlaylistView: View {
  let model: AppModel
  let playlistID: UUID
  @State private var addSheet: PlaylistSheetDestination?

  private var playlist: Playlist? { model.playlists.playlist(id: playlistID) }

  var body: some View {
    Group {
      if let playlist {
        VStack(spacing: 0) {
          header(playlist)
          Divider()
          if playlist.items.isEmpty {
            ContentUnavailableView {
              Label("No Links Yet", systemImage: "link.badge.plus")
            } description: {
              Text(
                "Paste one or more YouTube URLs. The playlist stores only those references and lightweight display metadata."
              )
            } actions: {
              Button("Add YouTube URLs") { addSheet = PlaylistSheetDestination() }
                .buttonStyle(.borderedProminent)
            }
          } else {
            List {
              ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                PlaylistItemRow(model: model, playlistID: playlistID, index: index, item: item)
                  .listRowSeparator(.hidden)
              }
            }
            .listStyle(.plain)
          }
        }
        .navigationTitle(playlist.name)
      } else {
        ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list")
      }
    }
    .sheet(item: $addSheet) { _ in
      AddPlaylistURLsSheet(model: model, playlistID: playlistID)
    }
  }

  private func header(_ playlist: Playlist) -> some View {
    HStack(spacing: 18) {
      ZStack {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
          )
        Image(systemName: "music.note.list")
          .font(.system(size: 36, weight: .semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 104, height: 104)

      VStack(alignment: .leading, spacing: 7) {
        Text(playlist.name)
          .font(.system(size: 27, weight: .bold, design: .rounded))
        Label("URL-only playlist", systemImage: "link")
          .font(.caption.bold())
          .foregroundStyle(.purple)
        Text(
          "\(playlist.items.count) \(playlist.items.count == 1 ? "song" : "songs") • Downloaded songs play locally; all others stream without being saved."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        addSheet = PlaylistSheetDestination()
      } label: {
        Label("Add URLs", systemImage: "plus")
      }
      .buttonStyle(.bordered)
      Button {
        model.playPlaylist(playlistID)
      } label: {
        Label("Play", systemImage: "play.fill")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(playlist.items.isEmpty)
    }
    .padding(24)
    .background(.thinMaterial)
  }
}

private struct PlaylistItemRow: View {
  let model: AppModel
  let playlistID: UUID
  let index: Int
  let item: SearchResult

  var body: some View {
    HStack(spacing: 13) {
      Text("\(index + 1)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
        .frame(width: 24, alignment: .trailing)
      ArtworkView(remoteURL: item.thumbnailURL, cornerRadius: 8)
        .frame(width: 54, height: 54)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title).font(.headline).lineLimit(1)
        HStack {
          Text(item.artist)
          if model.library.contains(item.id) {
            Label("Local", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else {
            Label("Stream", systemImage: "dot.radiowaves.left.and.right")
              .foregroundStyle(.blue)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      if let duration = item.duration {
        Text(DurationFormatter.string(duration))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Button {
        model.keep(item)
      } label: {
        Image(systemName: model.library.contains(item.id) ? "checkmark" : "arrow.down")
      }
      .buttonStyle(.borderless)
      .disabled(model.library.contains(item.id))
      .help(model.library.contains(item.id) ? "Already downloaded" : "Download and keep")
      Button {
        model.playPlaylist(playlistID, startingAt: index)
      } label: {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.borderless)
      Button {
        model.playlists.removeItem(id: item.id, from: playlistID)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Remove link from playlist")
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.playPlaylist(playlistID, startingAt: index) }
  }
}

private struct AddPlaylistURLsSheet: View {
  let model: AppModel
  let playlistID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var isAdding = false
  @State private var resolutionID: UUID?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add YouTube URLs")
        .font(.title2.bold())
      Text(
        "Paste one video URL per line. Liltfinch stores the URL and small display metadata; links can still be saved when metadata is temporarily unavailable."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      TextEditor(text: $text)
        .font(.body.monospaced())
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .frame(minHeight: 150)
        .focused($focused)
      if let error = model.search.errorMessage {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") {
          if let resolutionID { model.search.cancel(resolutionID) }
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button {
          isAdding = true
          resolutionID = model.search.resolveURLLines(text) { items in
            resolutionID = nil
            if !items.isEmpty { model.playlists.add(items, to: playlistID) }
            isAdding = false
            if !items.isEmpty, model.search.errorMessage == nil {
              dismiss()
            }
          }
        } label: {
          if isAdding { ProgressView().controlSize(.small) } else { Text("Add Links") }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
      }
    }
    .padding(24)
    .frame(width: 560, height: 360)
    .onAppear { focused = true }
    .onDisappear {
      if let resolutionID { model.search.cancel(resolutionID) }
    }
  }
}
