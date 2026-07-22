import AppKit
import SwiftUI

struct LibraryView: View {
  let model: AppModel
  @State private var query = ""
  @State private var gridMode = true

  private var filteredTracks: [Track] {
    guard !query.isEmpty else { return model.library.tracks }
    return model.library.tracks.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.artist.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    Group {
      if model.library.tracks.isEmpty {
        ContentUnavailableView {
          Label("Your Library Is Empty", systemImage: "music.note.house")
        } description: {
          Text(
            "Choose Download on a result or playlist song to keep it offline. Play Once never adds files here."
          )
        } actions: {
          Button("Find Music") { model.selection = .discover }
            .buttonStyle(.borderedProminent)
        }
      } else if gridMode {
        grid
      } else {
        list
      }
    }
    .navigationTitle("Library")
    .searchable(text: $query, prompt: "Search your library")
    .toolbar {
      ToolbarItemGroup {
        Picker("Layout", selection: $gridMode) {
          Image(systemName: "square.grid.2x2").tag(true)
          Image(systemName: "list.bullet").tag(false)
        }
        .pickerStyle(.segmented)
        .frame(width: 80)

        Button {
          NSWorkspace.shared.activateFileViewerSelecting([model.library.mediaDirectory])
        } label: {
          Label("Show Library Folder", systemImage: "folder")
        }
      }
    }
    .overlay(alignment: .bottom) {
      if let error = model.library.errorMessage {
        ErrorCard(message: error).padding()
      }
    }
  }

  private var grid: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 165, maximum: 220), spacing: 20)],
        spacing: 24
      ) {
        ForEach(filteredTracks) { track in
          LibraryCard(model: model, track: track)
        }
      }
      .padding(26)
    }
  }

  private var list: some View {
    List(filteredTracks) { track in
      LibraryRow(model: model, track: track)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }
    .listStyle(.plain)
  }
}

private struct LibraryCard: View {
  let model: AppModel
  let track: Track
  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack {
        ArtworkView(remoteURL: track.thumbnailURL, localURL: track.artworkURL, cornerRadius: 14)
          .aspectRatio(1, contentMode: .fit)
        if hovered {
          Circle()
            .fill(.ultraThickMaterial)
            .frame(width: 48, height: 48)
            .overlay {
              Image(systemName: "play.fill")
                .font(.title3)
                .offset(x: 1)
            }
            .shadow(radius: 10)
        }
      }
      Text(track.title)
        .font(.headline)
        .lineLimit(1)
      HStack {
        Text(track.artist).lineLimit(1)
        Spacer()
        if let size = track.fileSize {
          Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture(count: 2) { model.playLibraryTrack(track) }
    .contextMenu { LibraryContextMenu(model: model, track: track) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(track.title) by \(track.artist)")
  }
}

private struct LibraryRow: View {
  let model: AppModel
  let track: Track

  var body: some View {
    HStack(spacing: 13) {
      ArtworkView(remoteURL: track.thumbnailURL, localURL: track.artworkURL, cornerRadius: 8)
        .frame(width: 54, height: 54)
      VStack(alignment: .leading, spacing: 3) {
        Text(track.title).font(.headline).lineLimit(1)
        Text(track.artist).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let duration = track.duration {
        Text(DurationFormatter.string(duration))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      PlaylistMenu(model: model, item: track.searchResult)
      Button {
        model.playLibraryTrack(track)
      } label: {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.playLibraryTrack(track) }
    .contextMenu { LibraryContextMenu(model: model, track: track) }
  }
}

private struct LibraryContextMenu: View {
  let model: AppModel
  let track: Track

  var body: some View {
    Button("Play") { model.playLibraryTrack(track) }
    Menu("Add to Playlist") {
      ForEach(model.playlists.playlists) { playlist in
        Button(playlist.name) { model.playlists.add(track.searchResult, to: playlist.id) }
      }
    }
    Divider()
    Button("Show in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting([track.audioURL])
    }
    if let sourceURL = track.sourceURL {
      Button("Open on YouTube") { NSWorkspace.shared.open(sourceURL) }
    }
    Divider()
    Button("Move to Trash", role: .destructive) {
      if model.player.currentTrack?.localTrack?.localFilePath == track.localFilePath {
        model.player.stopForReplacement()
      }
      model.library.deleteFromLibrary(track)
    }
  }
}
