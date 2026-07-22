import SwiftUI

struct PlayerBar: View {
  let model: AppModel

  var body: some View {
    HStack(spacing: 16) {
      if let track = model.player.currentTrack {
        ArtworkView(remoteURL: track.thumbnailURL, localURL: track.artworkURL, cornerRadius: 9)
          .frame(width: 58, height: 58)
        VStack(alignment: .leading, spacing: 4) {
          Text(track.title)
            .font(.headline)
            .lineLimit(1)
          Text(track.artist)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Label(
            track.isStreaming
              ? (model.player.isBuffering ? "Buffering stream…" : "Streaming • Not saved")
              : (track.localTrack?.storage == .temporary
                ? "Deletes after playback" : "Saved in Library"),
            systemImage: track.isStreaming
              ? (model.player.isBuffering ? "hourglass" : "dot.radiowaves.left.and.right")
              : (track.localTrack?.storage == .temporary ? "trash" : "checkmark.circle.fill")
          )
          .font(.caption2.bold())
          .foregroundStyle(
            track.isStreaming ? .blue : (track.localTrack?.storage == .temporary ? .purple : .green)
          )
        }
        .frame(width: 220, alignment: .leading)
      } else if model.isPreparingPlayback {
        ZStack {
          RoundedRectangle(cornerRadius: 9).fill(.quaternary)
          ProgressView().controlSize(.small)
        }
        .frame(width: 58, height: 58)
        VStack(alignment: .leading, spacing: 4) {
          Text("Starting stream…").font(.headline)
          Text("Resolving audio without downloading the whole song.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(width: 220, alignment: .leading)
      } else if let message = model.playbackMessage ?? model.player.errorMessage {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.title2)
          .foregroundStyle(.red)
          .frame(width: 58)
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
          .frame(width: 220, alignment: .leading)
      }

      Spacer(minLength: 8)

      VStack(spacing: 7) {
        HStack(spacing: 18) {
          Button {
            model.toggleCurrentSongDislike()
          } label: {
            Image(
              systemName: model.currentRating == .disliked
                ? "hand.thumbsdown.fill" : "hand.thumbsdown"
            )
            .foregroundStyle(model.currentRating == .disliked ? .red : .secondary)
          }
          .buttonStyle(.plain)
          .disabled(model.player.currentTrack == nil)
          .help(model.currentRating == .disliked ? "Remove dislike" : "Dislike this song")
          .accessibilityLabel("Dislike current song")

          Button {
            model.previous()
          } label: {
            Image(systemName: "backward.fill")
          }
          .buttonStyle(.plain)
          .disabled(model.player.currentTrack == nil)

          Button {
            model.player.togglePlayback()
          } label: {
            ZStack {
              Circle().fill(.primary)
              Image(
                systemName: model.player.isPlaying || model.player.isBuffering
                  ? "pause.fill" : "play.fill"
              )
              .foregroundStyle(.background)
              .offset(x: model.player.isPlaying || model.player.isBuffering ? 0 : 1)
            }
            .frame(width: 38, height: 38)
          }
          .buttonStyle(.plain)
          .disabled(model.player.currentTrack == nil)

          Button {
            model.next()
          } label: {
            Image(systemName: "forward.fill")
          }
          .buttonStyle(.plain)
          .disabled(!model.canPlayNext)

          Button {
            model.likeCurrentSong()
          } label: {
            Image(
              systemName: model.currentRating == .liked
                ? "hand.thumbsup.fill" : "hand.thumbsup"
            )
            .foregroundStyle(model.currentRating == .liked ? .green : .secondary)
          }
          .buttonStyle(.plain)
          .disabled(model.player.currentTrack == nil || model.currentRating == .liked)
          .help(model.currentRating == .liked ? "Already in Favorites" : "Like this song")
          .accessibilityLabel("Like current song")
        }

        HStack(spacing: 8) {
          Text(DurationFormatter.string(model.player.currentTime))
          Slider(
            value: Binding(
              get: { model.player.currentTime },
              set: { model.player.seek(to: $0) }
            ),
            in: 0...max(model.player.duration, 1)
          )
          Text(
            "−\(DurationFormatter.string(max(model.player.duration - model.player.currentTime, 0)))"
          )
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: 520)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 8) {
        HStack(spacing: 8) {
          Button {
            model.toggleAutoplay()
          } label: {
            Label("Autoplay", systemImage: "infinity")
          }
          .buttonStyle(.bordered)
          .tint(model.autoplay.isEnabled ? .accentColor : .secondary)
          .help(model.autoplay.isEnabled ? "Turn Autoplay off" : "Turn Autoplay on")

          if model.autoplay.isPreparing {
            ProgressView()
              .controlSize(.small)
              .help("Preparing the next song")
          } else if model.autoplay.nextItem != nil {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .help("The next song is ready")
          }
        }

        if let nextItem = model.autoplay.nextItem {
          Text(
            model.autoplay.isPreparing ? "Preparing: \(nextItem.title)" : "Next: \(nextItem.title)"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(nextItem.title)
        } else if model.autoplay.isPreparing {
          Text("Choosing your next song…")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          Image(systemName: "speaker.fill")
            .foregroundStyle(.secondary)
          Slider(
            value: Binding(
              get: { model.player.volume },
              set: { model.player.volume = $0 }
            ),
            in: 0...1
          )
          .frame(width: 105)
          Image(systemName: "speaker.wave.3.fill")
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 220, alignment: .trailing)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 11)
    .frame(minHeight: 96)
    .background(.ultraThickMaterial)
  }
}
