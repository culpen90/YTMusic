import SwiftUI

struct FavoritesView: View {
  let model: AppModel

  private var items: [SearchResult] { model.feedback.favoriteItems }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if items.isEmpty {
        ContentUnavailableView {
          Label("No Favorites Yet", systemImage: "heart")
        } description: {
          Text(
            "Give a playing song a thumbs up and it will appear here automatically. Only songs with a thumbs up are included."
          )
        } actions: {
          Button("Find Music") { model.selection = .discover }
            .buttonStyle(.borderedProminent)
        }
      } else {
        List {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            FavoriteItemRow(model: model, index: index, item: item)
              .listRowSeparator(.hidden)
          }
        }
        .listStyle(.plain)
      }
    }
    .navigationTitle("Favorites")
  }

  private var header: some View {
    HStack(spacing: 18) {
      ZStack {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.green, .mint, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
          )
        Image(systemName: "heart.fill")
          .font(.system(size: 36, weight: .semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 104, height: 104)

      VStack(alignment: .leading, spacing: 7) {
        Text("Favorites")
          .font(.system(size: 27, weight: .bold, design: .rounded))
        Label("Automatic playlist", systemImage: "sparkles")
          .font(.caption.bold())
          .foregroundStyle(.green)
        Text(
          "\(items.count) \(items.count == 1 ? "song" : "songs") • Only thumbs-up songs appear here. Downloaded songs play locally; all others stream without being saved."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        model.playFavorites()
      } label: {
        Label("Play", systemImage: "play.fill")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(items.isEmpty)
    }
    .padding(24)
    .background(.thinMaterial)
  }
}

private struct FavoriteItemRow: View {
  let model: AppModel
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
        model.playFavorites(startingAt: index)
      } label: {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.borderless)
      Button {
        model.removeFromFavorites(item)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Remove from Favorites and clear thumbs up")
      .accessibilityLabel("Remove \(item.title) from Favorites")
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.playFavorites(startingAt: index) }
  }
}
