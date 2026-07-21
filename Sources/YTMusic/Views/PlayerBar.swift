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
            track.storage == .temporary ? "Deletes after playback" : "Saved in Library",
            systemImage: track.storage == .temporary ? "trash" : "checkmark.circle.fill"
          )
          .font(.caption2.bold())
          .foregroundStyle(track.storage == .temporary ? .purple : .green)
        }
        .frame(width: 210, alignment: .leading)
      } else if model.isPreparingPlayback {
        ZStack {
          RoundedRectangle(cornerRadius: 9).fill(.quaternary)
          ProgressView().controlSize(.small)
        }
        .frame(width: 58, height: 58)
        VStack(alignment: .leading, spacing: 4) {
          Text("Preparing temporary audio…").font(.headline)
          Text("The file will be removed when playback finishes.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(width: 210, alignment: .leading)
      } else if let message = model.playbackMessage ?? model.player.errorMessage {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.title2)
          .foregroundStyle(.red)
          .frame(width: 58)
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
          .frame(width: 210, alignment: .leading)
      }

      Spacer(minLength: 8)

      VStack(spacing: 7) {
        HStack(spacing: 22) {
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
              Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                .foregroundStyle(.background)
                .offset(x: model.player.isPlaying ? 0 : 1)
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
          .disabled(
            model.player.currentTrack == nil && !model.isPreparingPlayback
              && !model.hasActivePlaylistSession
          )
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
        .frame(width: 100)
        Image(systemName: "speaker.wave.3.fill")
          .foregroundStyle(.secondary)
      }
      .frame(width: 155)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 11)
    .frame(minHeight: 86)
    .background(.ultraThickMaterial)
  }
}
