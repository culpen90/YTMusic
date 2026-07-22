import AppKit
import SwiftUI

@main
@MainActor
struct LiltfinchApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model: AppModel

  init() {
    ProcessGroupLauncher.launchIfRequested()
    AppMigration.migrateLegacyPreferences()
    _model = State(initialValue: AppModel())
  }

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .frame(minWidth: 980, minHeight: 640)
        .task {
          appDelegate.shutdownHandler = { [weak model] in await model?.shutdown() }
          model.toolchain.refresh()
        }
    }
    .defaultSize(width: 1180, height: 760)
    .commands {
      CommandMenu("Playback") {
        Button(model.player.isPlaybackRequested ? "Pause" : "Play") {
          model.player.togglePlayback()
        }
        .disabled(model.player.currentTrack == nil)

        Button("Previous") { model.previous() }
          .keyboardShortcut(.leftArrow, modifiers: [.command])
        Button("Next") { model.next() }
          .keyboardShortcut(.rightArrow, modifiers: [.command])

        Divider()

        Button(model.currentRating == .liked ? "Current Song Is Liked" : "Like Current Song") {
          model.likeCurrentSong()
        }
        .disabled(model.player.currentTrack == nil || model.currentRating == .liked)

        Button(model.currentRating == .disliked ? "Remove Dislike" : "Dislike Current Song") {
          model.toggleCurrentSongDislike()
        }
        .disabled(model.player.currentTrack == nil)

        Button(model.autoplay.isEnabled ? "Turn Autoplay Off" : "Turn Autoplay On") {
          model.toggleAutoplay()
        }
      }
    }

    Settings {
      SettingsView(model: model)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var shutdownHandler: (() async -> Void)?
  private var isFinishingTermination = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if isFinishingTermination { return .terminateLater }
    guard let shutdownHandler else { return .terminateNow }
    isFinishingTermination = true
    Task {
      await shutdownHandler()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
