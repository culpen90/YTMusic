import Foundation
import Observation

enum SidebarSelection: Hashable {
  case discover
  case library
  case downloads
  case favorites
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
  let feedback: FeedbackStore
  let search: SearchStore
  let downloads: DownloadManager
  let player: PlayerStore
  let autoplay: AutoplayStore

  private struct PlaylistSession {
    let items: [SearchResult]
    var index: Int
  }

  private var playlistSession: PlaylistSession?
  private var playRequestToken = UUID()
  private var playbackTasks: [UUID: Task<Void, Never>] = [:]
  private var activePlaybackTaskID: UUID?
  private var failedPlaybackTrack: PlaybackTrack?
  private var recentlyPlayedIDs: [String] = []
  private var nextPreparationBarrier: Task<Void, Never>?
  private var waitingForPreparedNext = false
  private var waitingPlaylistItemID: String?
  private var isShuttingDown = false

  var canPlayNext: Bool {
    player.currentTrack != nil || isPreparingPlayback || playlistSession != nil
      || failedPlaybackTrack != nil || autoplay.preparedPlayback != nil || autoplay.isPreparing
  }
  var currentRating: SongRating? {
    player.currentTrack.flatMap { feedback.rating(for: $0.id) }
  }

  init() {
    let toolchain = ToolchainStore()
    let library = LibraryStore()
    let feedback = FeedbackStore(rootDirectory: library.rootDirectory)
    let player = PlayerStore()
    self.toolchain = toolchain
    self.library = library
    self.feedback = feedback
    self.player = player
    playlists = PlaylistStore(rootDirectory: library.rootDirectory)
    search = SearchStore(toolchain: toolchain)
    downloads = DownloadManager(toolchain: toolchain, library: library)
    autoplay = AutoplayStore(feedback: feedback, library: library)

    player.onTemporaryTrackFinished = { [weak library] track in
      library?.deleteTemporaryTrack(track)
    }
    player.onTrackStarted = { [weak library] track in
      library?.markPlayed(track)
    }
    player.onPlaybackStarted = { [weak self] track in
      self?.playbackStarted(track)
    }
    player.onTrackEnded = { [weak self] track in
      self?.advanceAfterPlayback(of: track)
    }
    player.onTrackFailed = { [weak self] track in
      self?.playbackFailed(track)
    }
    autoplay.onPreparationFinished = { [weak self] in
      self?.autoplayPreparationFinished()
    }
  }

  func play(_ item: SearchResult) {
    playlistSession = nil
    beginPlayback(of: item)
  }

  func likeCurrentSong() {
    guard let item = player.currentTrack?.metadata else { return }
    updateRating(.liked, for: item)
  }

  func toggleCurrentSongDislike() {
    guard let item = player.currentTrack?.metadata else { return }
    let updatedRating: SongRating? = feedback.rating(for: item) == .disliked ? nil : .disliked
    updateRating(updatedRating, for: item)
  }

  func removeFromFavorites(_ item: SearchResult) {
    guard feedback.rating(for: item) == .liked else { return }
    updateRating(nil, for: item)
  }

  private func updateRating(_ rating: SongRating?, for item: SearchResult) {
    feedback.setRating(rating, for: item)
    guard let currentItem = player.currentTrack?.metadata,
      queuedPlaylistItem(after: currentItem) == nil
    else { return }
    prepareNext(after: currentItem)
  }

  func toggleAutoplay() {
    let enabled = !autoplay.isEnabled
    autoplay.setEnabled(enabled)
    guard let item = player.currentTrack?.metadata else {
      if !enabled, waitingForPreparedNext, waitingPlaylistItemID == nil {
        waitingForPreparedNext = false
        isPreparingPlayback = false
        _ = autoplay.cancelPreparation()
      }
      return
    }

    if let queuedNext = queuedPlaylistItem(after: item) {
      if autoplay.nextItem?.id != queuedNext.id {
        prepareNext(after: item)
      }
      return
    }
    prepareNext(after: item)
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
    guard !isShuttingDown else { return }
    nextPreparationBarrier = cancelPendingPlayback()
    _ = autoplay.cancelPreparation()
    waitingForPreparedNext = false
    waitingPlaylistItemID = nil
    failedPlaybackTrack = nil
    playlistSession = nil
    isPreparingPlayback = false
    playbackMessage = nil
    player.stopForReplacement()
    player.play(track)
  }

  func playPlaylist(_ playlistID: UUID, startingAt index: Int = 0) {
    guard let playlist = playlists.playlist(id: playlistID),
      playlist.items.indices.contains(index)
    else { return }
    playlistSession = PlaylistSession(items: playlist.items, index: index)
    beginPlayback(of: playlist.items[index], preservePlaylistSession: true)
  }

  func playFavorites(startingAt index: Int = 0) {
    let items = feedback.favoriteItems
    guard items.indices.contains(index) else { return }
    playlistSession = PlaylistSession(items: items, index: index)
    beginPlayback(of: items[index], preservePlaylistSession: true)
  }

  func next() {
    guard !isShuttingDown else { return }
    if waitingForPreparedNext { return }

    if let currentTrack = player.currentTrack {
      cancelPendingPlayback()
      player.stopForReplacement()
      advanceAfterPlayback(of: currentTrack)
      return
    }

    if let failedPlaybackTrack {
      cancelPendingPlayback()
      self.failedPlaybackTrack = nil
      advanceAfterPlayback(of: failedPlaybackTrack)
      return
    }

    cancelPendingPlayback()
    _ = autoplay.cancelPreparation()
    guard var session = playlistSession else {
      isPreparingPlayback = false
      playbackMessage = nil
      player.errorMessage = nil
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

  func previous() {
    guard !isShuttingDown else { return }
    guard var session = playlistSession else {
      player.restart()
      return
    }
    if player.currentTime > 3 || session.index == 0 {
      player.restart()
      return
    }
    cancelPendingPlayback()
    _ = autoplay.cancelPreparation()
    player.stopForReplacement()
    session.index -= 1
    playlistSession = session
    beginPlayback(of: session.items[session.index], preservePlaylistSession: true)
  }

  func shutdown() async {
    isShuttingDown = true
    waitingForPreparedNext = false
    waitingPlaylistItemID = nil
    failedPlaybackTrack = nil
    cancelPendingPlayback()
    player.shutdown()
    await autoplay.shutdown()
    let tasksToFinish = Array(playbackTasks.values)
    for task in tasksToFinish {
      task.cancel()
    }
    for task in tasksToFinish {
      await task.value
    }
    self.playbackTasks.removeAll()
    await downloads.shutdown()
    await search.shutdown()
    await toolchain.shutdown()
    library.cleanupAllTemporaryFiles()
  }

  private func beginPlayback(of item: SearchResult, preservePlaylistSession: Bool = false) {
    guard !isShuttingDown else { return }
    let previousPlaybackTask = cancelPendingPlayback()
    let previousAutoplayTask = autoplay.cancelPreparation()
    if !preservePlaylistSession { playlistSession = nil }
    waitingForPreparedNext = false
    waitingPlaylistItemID = nil
    failedPlaybackTrack = nil
    player.stopForReplacement()
    player.errorMessage = nil
    playbackMessage = nil
    let token = UUID()
    playRequestToken = token

    if let keptTrack = library.track(withID: item.id),
      FileManager.default.fileExists(atPath: keptTrack.audioURL.path)
    {
      nextPreparationBarrier = previousPlaybackTask ?? nextPreparationBarrier
      isPreparingPlayback = false
      player.play(keptTrack)
      return
    }

    isPreparingPlayback = true
    let toolchainStatus = toolchain.status
    let taskID = UUID()
    let playbackTask = Task { [weak self] in
      if let previousPlaybackTask {
        await previousPlaybackTask.value
      }
      if let previousAutoplayTask {
        await previousAutoplayTask.value
      }
      do {
        try Task.checkCancellation()
        let stream = try await YTDLPService(toolchain: toolchainStatus)
          .resolvePlaybackStream(for: item)
        try Task.checkCancellation()
        guard let self else { return }
        self.finishPlaybackTask(taskID)
        guard self.playRequestToken == token else { return }
        self.nextPreparationBarrier = nil
        self.isPreparingPlayback = false
        self.player.play(stream: item, resolvedStream: stream)
      } catch {
        guard let self else { return }
        self.finishPlaybackTask(taskID)
        guard self.playRequestToken == token else { return }
        self.nextPreparationBarrier = nil
        self.isPreparingPlayback = false
        self.playbackMessage = error.localizedDescription
      }
    }
    playbackTasks[taskID] = playbackTask
    activePlaybackTaskID = taskID
  }

  private func playbackStarted(_ track: PlaybackTrack) {
    guard !isShuttingDown else { return }
    waitingForPreparedNext = false
    waitingPlaylistItemID = nil
    failedPlaybackTrack = nil
    isPreparingPlayback = false
    playbackMessage = nil

    recentlyPlayedIDs.removeAll { $0 == track.id }
    recentlyPlayedIDs.append(track.id)
    if recentlyPlayedIDs.count > 50 {
      recentlyPlayedIDs.removeFirst(recentlyPlayedIDs.count - 50)
    }
    prepareNext(after: track.metadata)
  }

  private func playbackFailed(_ track: PlaybackTrack) {
    guard !isShuttingDown else { return }
    failedPlaybackTrack = track
    waitingForPreparedNext = false
    waitingPlaylistItemID = nil
    isPreparingPlayback = false
  }

  private func prepareNext(after item: SearchResult) {
    guard !isShuttingDown else { return }
    let queuedNext = queuedPlaylistItem(after: item)
    guard queuedNext != nil || autoplay.isEnabled else {
      _ = autoplay.cancelPreparation()
      return
    }
    let barrierTask = nextPreparationBarrier
    nextPreparationBarrier = nil
    autoplay.prepareNext(
      after: item,
      queuedNext: queuedNext,
      excluding: Set(recentlyPlayedIDs),
      toolchain: toolchain.status,
      waitingFor: barrierTask
    )
  }

  private func queuedPlaylistItem(after currentItem: SearchResult) -> SearchResult? {
    guard let session = playlistSession,
      session.items.indices.contains(session.index),
      session.items[session.index].id == currentItem.id
    else { return nil }
    let nextIndex = session.index + 1
    guard session.items.indices.contains(nextIndex) else { return nil }
    return session.items[nextIndex]
  }

  private func advanceAfterPlayback(of finishedTrack: PlaybackTrack) {
    guard !isShuttingDown else { return }
    player.errorMessage = nil
    playbackMessage = nil

    if var session = playlistSession {
      let nextIndex = session.index + 1
      if session.items.indices.contains(nextIndex) {
        session.index = nextIndex
        playlistSession = session
        let item = session.items[nextIndex]
        if let prepared = autoplay.consumePrepared(matching: item.id) {
          startPreparedPlayback(prepared)
        } else if autoplay.isPreparing, autoplay.nextItem?.id == item.id {
          waitingForPreparedNext = true
          waitingPlaylistItemID = item.id
          isPreparingPlayback = true
        } else {
          beginPlayback(of: item, preservePlaylistSession: true)
        }
        return
      }
      playlistSession = nil
    }

    guard autoplay.isEnabled else {
      _ = autoplay.cancelPreparation()
      isPreparingPlayback = false
      return
    }

    if let prepared = autoplay.consumePrepared() {
      startPreparedPlayback(prepared)
      return
    }

    if !autoplay.isPreparing {
      prepareNext(after: finishedTrack.metadata)
    }
    guard autoplay.isPreparing else {
      isPreparingPlayback = false
      playbackMessage =
        autoplay.errorMessage ?? AutoplayPreparationError.noRecommendation.localizedDescription
      return
    }
    waitingForPreparedNext = true
    waitingPlaylistItemID = nil
    isPreparingPlayback = true
  }

  private func autoplayPreparationFinished() {
    guard !isShuttingDown, waitingForPreparedNext else { return }

    if let expectedItemID = waitingPlaylistItemID {
      if let prepared = autoplay.consumePrepared(matching: expectedItemID) {
        startPreparedPlayback(prepared)
        return
      }
      guard !autoplay.isPreparing else { return }
      waitingForPreparedNext = false
      waitingPlaylistItemID = nil
      isPreparingPlayback = false
      guard let session = playlistSession,
        session.items.indices.contains(session.index),
        session.items[session.index].id == expectedItemID
      else {
        playbackMessage = autoplay.errorMessage
        return
      }
      beginPlayback(of: session.items[session.index], preservePlaylistSession: true)
      return
    }

    if let prepared = autoplay.consumePrepared() {
      startPreparedPlayback(prepared)
      return
    }
    guard !autoplay.isPreparing else { return }
    waitingForPreparedNext = false
    isPreparingPlayback = false
    playbackMessage =
      autoplay.errorMessage ?? AutoplayPreparationError.noRecommendation.localizedDescription
  }

  private func startPreparedPlayback(_ prepared: PreparedPlayback) {
    guard !isShuttingDown else { return }
    waitingForPreparedNext = false
    waitingPlaylistItemID = nil
    isPreparingPlayback = false
    playbackMessage = nil
    player.errorMessage = nil

    switch prepared.source {
    case .local:
      guard let currentLibraryTrack = library.track(withID: prepared.item.id),
        FileManager.default.fileExists(atPath: currentLibraryTrack.audioURL.path)
      else {
        beginPlayback(of: prepared.item, preservePlaylistSession: playlistSession != nil)
        return
      }
      player.play(currentLibraryTrack)
    case .stream(let stream):
      player.play(stream: prepared.item, resolvedStream: stream)
    }
  }

  @discardableResult
  private func cancelPendingPlayback() -> Task<Void, Never>? {
    playRequestToken = UUID()
    let playbackTask = activePlaybackTaskID.flatMap { playbackTasks[$0] }
    playbackTask?.cancel()
    isPreparingPlayback = false
    return playbackTask
  }

  private func finishPlaybackTask(_ taskID: UUID) {
    playbackTasks.removeValue(forKey: taskID)
    if activePlaybackTaskID == taskID {
      activePlaybackTaskID = nil
    }
  }
}
