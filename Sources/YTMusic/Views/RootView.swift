import SwiftUI

private enum SidebarSheet: String, Identifiable {
  case newPlaylist
  var id: String { rawValue }
}

struct RootView: View {
  @Bindable var model: AppModel
  @State private var sheet: SidebarSheet?

  var body: some View {
    VStack(spacing: 0) {
      NavigationSplitView {
        sidebar
          .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
      } detail: {
        detail
      }
      .navigationSplitViewStyle(.balanced)

      if model.player.currentTrack != nil || model.isPreparingPlayback
        || model.playbackMessage != nil || model.player.errorMessage != nil
      {
        Divider()
        PlayerBar(model: model)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: model.player.currentTrack?.audioURL.absoluteString)
    .sheet(item: $sheet) { destination in
      switch destination {
      case .newPlaylist:
        NewPlaylistSheet(model: model)
      }
    }
    .alert(
      "Playlist Error",
      isPresented: Binding(
        get: { model.playlists.errorMessage != nil },
        set: { if !$0 { model.playlists.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.playlists.errorMessage = nil }
    } message: {
      Text(model.playlists.errorMessage ?? "The playlist change could not be saved.")
    }
    .alert(
      "Rating Error",
      isPresented: Binding(
        get: { model.feedback.errorMessage != nil },
        set: { if !$0 { model.feedback.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.feedback.errorMessage = nil }
    } message: {
      Text(model.feedback.errorMessage ?? "The rating change could not be saved.")
    }
  }

  private var sidebar: some View {
    List(selection: $model.selection) {
      Section {
        Label("Discover", systemImage: "sparkle.magnifyingglass")
          .tag(SidebarSelection.discover)
        Label("Library", systemImage: "music.note.house")
          .tag(SidebarSelection.library)
        HStack {
          Label("Downloads", systemImage: "arrow.down.circle")
          Spacer()
          if model.downloads.activeCount > 0 {
            Text("\(model.downloads.activeCount)")
              .font(.caption2.bold())
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(.tint, in: Capsule())
              .foregroundStyle(.white)
          }
        }
        .tag(SidebarSelection.downloads)
      }

      Section {
        HStack {
          Label("Favorites", systemImage: "heart.fill")
          Spacer()
          if !model.feedback.favoriteItems.isEmpty {
            Text("\(model.feedback.favoriteItems.count)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .tag(SidebarSelection.favorites)

        ForEach(model.playlists.playlists) { playlist in
          Label(playlist.name, systemImage: "music.note.list")
            .tag(SidebarSelection.playlist(playlist.id))
            .contextMenu {
              Button("Delete Playlist", role: .destructive) {
                if model.selection == .playlist(playlist.id) {
                  model.selection = .discover
                }
                model.playlists.delete(playlist.id)
              }
            }
        }
      } header: {
        HStack {
          Text("Playlists")
          Spacer()
          Button {
            sheet = .newPlaylist
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.plain)
          .help("New Playlist")
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .top) {
      BrandHeader()
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch model.selection ?? .discover {
    case .discover:
      DiscoverView(model: model)
    case .library:
      LibraryView(model: model)
    case .downloads:
      DownloadsView(model: model)
    case .favorites:
      FavoritesView(model: model)
    case .playlist(let id):
      PlaylistView(model: model, playlistID: id)
    }
  }
}

private struct BrandHeader: View {
  var body: some View {
    HStack(spacing: 11) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.pink, .purple, .indigo],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        Image(systemName: "waveform")
          .font(.title3.bold())
          .foregroundStyle(.white)
      }
      .frame(width: 38, height: 38)

      VStack(alignment: .leading, spacing: 1) {
        Text("YTMusic")
          .font(.headline)
        Text("Play clean. Keep by choice.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.bar)
  }
}

private struct NewPlaylistSheet: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("New Playlist")
        .font(.title2.bold())
      Text(
        "Playlists save YouTube links only. Songs stream when needed unless they are already in your library."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      TextField("Playlist name", text: $name)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .onSubmit(create)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Create", action: create)
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 430)
    .onAppear { isFocused = true }
  }

  private func create() {
    if let id = model.playlists.create(name: name) {
      model.selection = .playlist(id)
      dismiss()
    }
  }
}
