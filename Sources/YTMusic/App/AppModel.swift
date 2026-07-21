import Foundation
import Observation

enum SidebarSelection: Hashable {
  case discover
  case library
  case downloads
  case playlist(UUID)
}

@MainActor
@Observable
final class AppModel {
  var selection: SidebarSelection? = .discover
  var isPreparingPlayback = false
  var playbackMessage: String?

  let toolchain: ToolchainStore
  let library: LibraryStore
  let playlists: PlaylistStore
  let search: SearchStore
  let downloads: DownloadManager
  let player: PlayerStore

  private struct PlaylistSession {
    let items: [SearchResult]
    var index: Int
  }

  private var playlistSession: PlaylistSession?
  private var playRequestToken = UUID()
  private var pendingPlaybackJobID: UUID?

  var hasActivePlaylistSession: Bool { playlistSession != nil }

  init() {
    let toolchain = ToolchainStore()
    let library = LibraryStore()
    self.toolchain = toolchain
    self.library = library
    playlists = PlaylistStore(rootDirectory: library.rootDirectory)
    search = SearchStore(toolchain: toolchain)
    downloads = DownloadManager(toolchain: toolchain, library: library)
    player = PlayerStore()

    player.onTemporaryTrackFinished = { [weak library] track in
      library?.deleteTemporaryTrack(track)
    }
    player.onTrackStarted = { [weak library] track in
      library?.markPlayed(track)
    }
    player.onTrackEnded = { [weak self] _ in
      self?.advancePlaylist()
    }
  }

  func play(_ item: SearchResult) {
    playlistSession = nil
    beginPlayback(of: item)
  }

  func keep(_ item: SearchResult) {
    downloads.enqueue(item, intent: .keep)
  }

  func retry(_ job: DownloadJob) {
    if job.intent == .playOnce {
      play(job.result)
    } else {
      downloads.retry(job.id)
    }
  }

  func playLibraryTrack(_ track: Track) {
    cancelPendingPlayback()
    playlistSession = nil
    playbackMessage = nil
    player.play(track)
  }

  func playPlaylist(_ playlistID: UUID, startingAt index: Int = 0) {
    guard let playlist = playlists.playlist(id: playlistID),
      playlist.items.indices.contains(index)
    else { return }
    playlistSession = PlaylistSession(items: playlist.items, index: index)
    beginPlayback(of: playlist.items[index], preservePlaylistSession: true)
  }

  func next() {
    cancelPendingPlayback()
    guard playlistSession != nil else {
      player.stopForReplacement()
      playbackMessage = nil
      player.errorMessage = nil
      return
    }
    player.stopForReplacement()
    advancePlaylist()
  }

  func previous() {
    guard var session = playlistSession else {
      player.restart()
      return
    }
    if player.currentTime > 3 || session.index == 0 {
      player.restart()
      return
    }
    cancelPendingPlayback()
    player.stopForReplacement()
    session.index -= 1
    playlistSession = session
    beginPlayback(of: session.items[session.index], preservePlaylistSession: true)
  }

  func shutdown() async {
    cancelPendingPlayback()
    player.shutdown()
    await downloads.shutdown()
    await search.shutdown()
    await toolchain.shutdown()
    library.cleanupAllTemporaryFiles()
  }

  private func beginPlayback(of item: SearchResult, preservePlaylistSession: Bool = false) {
    cancelPendingPlayback()
    if !preservePlaylistSession { playlistSession = nil }
    player.stopForReplacement()
    player.errorMessage = nil
    playbackMessage = nil
    let token = UUID()
    playRequestToken = token

    if let keptTrack = library.track(withID: item.id) {
      isPreparingPlayback = false
      player.play(keptTrack)
      return
    }

    isPreparingPlayback = true
    pendingPlaybackJobID = downloads.enqueue(item, intent: .playOnce) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let track):
        guard self.playRequestToken == token else {
          self.library.deleteTemporaryTrack(track)
          return
        }
        self.pendingPlaybackJobID = nil
        self.isPreparingPlayback = false
        self.player.play(track)
      case .failure(let error):
        guard self.playRequestToken == token else { return }
        self.pendingPlaybackJobID = nil
        self.isPreparingPlayback = false
        self.playbackMessage = error.localizedDescription
      }
    }
  }

  private func advancePlaylist() {
    guard var session = playlistSession else {
      playlistSession = nil
      return
    }
    session.index += 1
    guard session.items.indices.contains(session.index) else {
      playlistSession = nil
      isPreparingPlayback = false
      return
    }
    playlistSession = session
    beginPlayback(of: session.items[session.index], preservePlaylistSession: true)
  }

  private func cancelPendingPlayback() {
    playRequestToken = UUID()
    if let pendingPlaybackJobID {
      self.pendingPlaybackJobID = nil
      downloads.cancel(pendingPlaybackJobID)
    }
    isPreparingPlayback = false
  }
}
