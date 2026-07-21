import SwiftUI

struct DiscoverView: View {
  let model: AppModel
  @FocusState private var searchFocused: Bool

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        hero
        if !model.toolchain.status.isReady {
          DependencyBanner(model: model)
        }
        content
      }
      .padding(28)
      .frame(maxWidth: 980, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(
      LinearGradient(
        colors: [Color.purple.opacity(0.08), Color.clear],
        startPoint: .top,
        endPoint: .center
      )
    )
    .navigationTitle("Discover")
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text("What do you want to hear?")
          .font(.system(size: 32, weight: .bold, design: .rounded))
        Text("Search YouTube or paste a link. Play Once cleans itself up; Download keeps a copy.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Song, artist, or YouTube URL", text: Bindable(model.search).query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($searchFocused)
          .onSubmit { model.search.submit() }
        if model.search.isLoading {
          ProgressView().controlSize(.small)
        } else if !model.search.query.isEmpty {
          Button {
            model.search.query = ""
            model.search.results = []
            model.search.errorMessage = nil
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
        Button("Search") {
          model.search.submit()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(
          model.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.search.isLoading)
      }
      .padding(.leading, 16)
      .padding(.trailing, 8)
      .frame(height: 58)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(
            searchFocused ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.2),
            lineWidth: searchFocused ? 2 : 1)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if let error = model.search.errorMessage {
      ErrorCard(message: error)
    } else if model.search.isLoading && model.search.results.isEmpty {
      ForEach(0..<4, id: \.self) { _ in
        SearchResultRow.placeholder
      }
    } else if model.search.results.isEmpty {
      EmptyDiscoverState()
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text("Results")
          .font(.title2.bold())
        ForEach(model.search.results) { result in
          SearchResultRow(model: model, result: result)
        }
      }
    }
  }
}

struct SearchResultRow: View {
  let model: AppModel
  let result: SearchResult

  static var placeholder: some View {
    HStack(spacing: 14) {
      RoundedRectangle(cornerRadius: 10).fill(.quaternary).frame(width: 74, height: 74)
      VStack(alignment: .leading) {
        Text("A song title that is loading")
        Text("Artist name")
      }
      Spacer()
    }
    .padding(10)
    .redacted(reason: .placeholder)
  }

  var body: some View {
    HStack(spacing: 14) {
      ArtworkView(remoteURL: result.thumbnailURL, cornerRadius: 10)
        .frame(width: 74, height: 74)

      VStack(alignment: .leading, spacing: 5) {
        Text(result.title)
          .font(.headline)
          .lineLimit(2)
        HStack(spacing: 7) {
          Text(result.artist)
          if let duration = result.duration {
            Text("•")
            Text(DurationFormatter.string(duration))
          }
          if model.library.contains(result.id) {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)
      PlaylistMenu(model: model, item: result)

      Button {
        model.keep(result)
      } label: {
        Label(
          model.library.contains(result.id) ? "Saved" : "Download",
          systemImage: model.library.contains(result.id) ? "checkmark" : "arrow.down")
      }
      .buttonStyle(.bordered)
      .disabled(model.library.contains(result.id))

      Button {
        model.play(result)
      } label: {
        Label("Play Once", systemImage: "play.fill")
      }
      .buttonStyle(.borderedProminent)
      .help("Fetch temporarily, play, then delete the file")
    }
    .padding(10)
    .background(
      .background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.secondary.opacity(0.13))
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.play(result) }
  }
}

struct PlaylistMenu: View {
  let model: AppModel
  let item: SearchResult

  var body: some View {
    Menu {
      if model.playlists.playlists.isEmpty {
        Text("Create a playlist from the sidebar")
      } else {
        ForEach(model.playlists.playlists) { playlist in
          Button(playlist.name) {
            model.playlists.add(item, to: playlist.id)
          }
        }
      }
    } label: {
      Image(systemName: "text.badge.plus")
    }
    .menuStyle(.borderlessButton)
    .frame(width: 28)
    .help("Add to Playlist")
  }
}

private struct EmptyDiscoverState: View {
  var body: some View {
    HStack(spacing: 16) {
      FeatureCard(
        icon: "play.circle.fill",
        title: "Play Once",
        detail: "Audio lives in a temporary cache and is erased when you finish or skip it.",
        color: .purple
      )
      FeatureCard(
        icon: "arrow.down.circle.fill",
        title: "Download",
        detail: "Only this action adds a lasting audio file to your offline library.",
        color: .blue
      )
      FeatureCard(
        icon: "music.note.list",
        title: "URL Playlists",
        detail: "Playlists retain links and metadata—not media files.",
        color: .pink
      )
    }
  }
}

private struct FeatureCard: View {
  let icon: String
  let title: String
  let detail: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: icon)
        .font(.title)
        .foregroundStyle(color)
      Text(title).font(.headline)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct DependencyBanner: View {
  let model: AppModel

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "wrench.and.screwdriver.fill")
        .font(.title2)
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 3) {
        Text("Downloader setup needed").font(.headline)
        Text("YTMusic needs yt-dlp and FFmpeg. You can install or configure them in Settings.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      SettingsLink {
        Text("Open Settings")
      }
      .buttonStyle(.bordered)
      Button("Install with Homebrew") {
        model.toolchain.installWithHomebrew()
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.toolchain.isInstalling)
    }
    .padding(16)
    .background(
      Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.orange.opacity(0.28))
    }
  }
}

struct ErrorCard: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .foregroundStyle(.red)
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
  }
}
