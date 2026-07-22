import Foundation

enum AppIdentity {
  static let name = "Liltfinch"
  static let legacyName = "YTMusic"
  static let bundleIdentifier = "com.culpen.liltfinch"
  static let legacyBundleIdentifier = "com.culpen.ytmusic"
  static let preferenceMigrationVersionKey = "liltfinch.legacyPreferencesMigrationVersion"
  static let storageMigrationPendingFilename = ".liltfinch-storage-migration-pending"
  static let storageMigrationCompleteFilename = ".liltfinch-storage-migration-v1"

  static let preferenceKeys = [
    "audioFormat",
    "downloaderPath",
    "ffmpegPath",
    "autoplayEnabled",
  ]
}

struct AppStorageResolution {
  let rootDirectory: URL
  let legacyRootDirectory: URL?
  let warning: String?
}

enum AppMigration {
  static func migrateLegacyPreferences(
    to current: UserDefaults = .standard,
    legacyValues: [String: Any]? = nil
  ) {
    guard current.integer(forKey: AppIdentity.preferenceMigrationVersionKey) < 1 else {
      return
    }
    let values =
      legacyValues
      ?? UserDefaults.standard.persistentDomain(
        forName: AppIdentity.legacyBundleIdentifier)
      ?? [:]

    for key in AppIdentity.preferenceKeys
    where current.object(forKey: key) == nil {
      guard let value = values[key] else { continue }
      current.set(value, forKey: key)
    }
    current.set(1, forKey: AppIdentity.preferenceMigrationVersionKey)
  }

  static func resolveApplicationSupportRoot(
    fileManager: FileManager,
    baseDirectory: URL
  ) -> AppStorageResolution {
    let currentRoot = baseDirectory.appendingPathComponent(
      AppIdentity.name, isDirectory: true)
    let legacyRoot = baseDirectory.appendingPathComponent(
      AppIdentity.legacyName, isDirectory: true)

    if pathEntryExists(currentRoot, fileManager: fileManager) {
      return resolveExistingCurrentRoot(
        fileManager: fileManager,
        currentRoot: currentRoot,
        legacyRoot: legacyRoot)
    }

    guard pathEntryExists(legacyRoot, fileManager: fileManager) else {
      return AppStorageResolution(
        rootDirectory: currentRoot,
        legacyRootDirectory: nil,
        warning: nil)
    }

    guard isSecureDirectory(legacyRoot) else {
      return AppStorageResolution(
        rootDirectory: currentRoot,
        legacyRootDirectory: nil,
        warning:
          "Legacy YTMusic data was left untouched because its storage folder is unsafe."
      )
    }

    do {
      try writeMarker(
        named: AppIdentity.storageMigrationPendingFilename,
        in: legacyRoot,
        fileManager: fileManager)
      try fileManager.moveItem(at: legacyRoot, to: currentRoot)
      return AppStorageResolution(
        rootDirectory: currentRoot,
        legacyRootDirectory: legacyRoot,
        warning: nil)
    } catch {
      if pathEntryExists(currentRoot, fileManager: fileManager) {
        return resolveExistingCurrentRoot(
          fileManager: fileManager,
          currentRoot: currentRoot,
          legacyRoot: legacyRoot)
      }
      if pathEntryExists(legacyRoot, fileManager: fileManager),
        isSecureDirectory(legacyRoot)
      {
        return AppStorageResolution(
          rootDirectory: legacyRoot,
          legacyRootDirectory: nil,
          warning:
            "Liltfinch is using the legacy data folder because it could not be renamed: \(error.localizedDescription)"
        )
      }
      return AppStorageResolution(
        rootDirectory: currentRoot,
        legacyRootDirectory: nil,
        warning:
          "Liltfinch could not resolve its data-folder migration: \(error.localizedDescription)"
      )
    }
  }

  static func completeStorageMigration(
    fileManager: FileManager,
    rootDirectory: URL
  ) throws {
    guard rootDirectory.lastPathComponent == AppIdentity.name else { return }
    try writeMarker(
      named: AppIdentity.storageMigrationCompleteFilename,
      in: rootDirectory,
      fileManager: fileManager)

    let pendingMarker = rootDirectory.appendingPathComponent(
      AppIdentity.storageMigrationPendingFilename)
    guard pathEntryExists(pendingMarker, fileManager: fileManager) else { return }
    guard isManagedRegularFile(pendingMarker, directlyInside: rootDirectory) else {
      throw AppMigrationError.unsafeMigrationState
    }
    try fileManager.removeItem(at: pendingMarker)
  }

  static func resolveCacheRoot(
    fileManager: FileManager,
    baseDirectory: URL
  ) -> URL {
    let currentRoot = baseDirectory.appendingPathComponent(
      AppIdentity.name, isDirectory: true)
    let legacyRoot = baseDirectory.appendingPathComponent(
      AppIdentity.legacyName, isDirectory: true)

    guard !pathEntryExists(currentRoot, fileManager: fileManager),
      pathEntryExists(legacyRoot, fileManager: fileManager),
      isSecureDirectory(legacyRoot)
    else { return currentRoot }

    do {
      try fileManager.moveItem(at: legacyRoot, to: currentRoot)
      return currentRoot
    } catch {
      if pathEntryExists(currentRoot, fileManager: fileManager) {
        return currentRoot
      }
      if pathEntryExists(legacyRoot, fileManager: fileManager),
        isSecureDirectory(legacyRoot)
      {
        return legacyRoot
      }
      return currentRoot
    }
  }

  private static func resolveExistingCurrentRoot(
    fileManager: FileManager,
    currentRoot: URL,
    legacyRoot: URL
  ) -> AppStorageResolution {
    let legacyExists = pathEntryExists(legacyRoot, fileManager: fileManager)
    let pendingMigration = hasValidMarker(
      named: AppIdentity.storageMigrationPendingFilename,
      in: currentRoot,
      fileManager: fileManager)
    let completedMigration = hasValidMarker(
      named: AppIdentity.storageMigrationCompleteFilename,
      in: currentRoot,
      fileManager: fileManager)

    if pendingMigration {
      return AppStorageResolution(
        rootDirectory: currentRoot,
        legacyRootDirectory: legacyRoot,
        warning:
          legacyExists
          ? "A legacy YTMusic data folder reappeared while Liltfinch was finishing migration. Liltfinch left it untouched."
          : nil)
    }

    if completedMigration || !legacyExists {
      return AppStorageResolution(
        rootDirectory: currentRoot,
        legacyRootDirectory: nil,
        warning:
          completedMigration && legacyExists
          ? "Both Liltfinch and legacy YTMusic data folders exist. Liltfinch is using its completed migration and left the legacy folder untouched."
          : nil)
    }

    guard isSecureDirectory(legacyRoot) else {
      return AppStorageResolution(
        rootDirectory: currentRoot,
        legacyRootDirectory: nil,
        warning:
          "Legacy YTMusic data was left untouched because its storage folder is unsafe."
      )
    }

    let currentHasData = containsUserData(currentRoot, fileManager: fileManager)
    let legacyHasData = containsUserData(legacyRoot, fileManager: fileManager)
    if legacyHasData && !currentHasData {
      return AppStorageResolution(
        rootDirectory: legacyRoot,
        legacyRootDirectory: nil,
        warning:
          "Liltfinch found an incomplete empty data folder and is using the populated legacy folder without modifying either one."
      )
    }

    return AppStorageResolution(
      rootDirectory: currentRoot,
      legacyRootDirectory: nil,
      warning:
        "Both Liltfinch and legacy YTMusic data folders contain state without a completed migration marker. Liltfinch is using the new folder and left the legacy folder untouched."
    )
  }

  private static func containsUserData(_ root: URL, fileManager: FileManager) -> Bool {
    for filename in [
      "library.json", "library.backup.json",
      "playlists.json", "playlists.backup.json",
      "feedback.json", "feedback.backup.json",
    ] where pathEntryExists(root.appendingPathComponent(filename), fileManager: fileManager) {
      return true
    }

    for directoryName in ["Media", "Artwork", "Recovered"] {
      let directory = root.appendingPathComponent(directoryName, isDirectory: true)
      if isSecureDirectory(directory),
        let entries = try? fileManager.contentsOfDirectory(atPath: directory.path),
        !entries.isEmpty
      {
        return true
      }
    }
    return false
  }

  private static func hasValidMarker(
    named filename: String,
    in root: URL,
    fileManager: FileManager
  ) -> Bool {
    let marker = root.appendingPathComponent(filename)
    return pathEntryExists(marker, fileManager: fileManager)
      && isManagedRegularFile(marker, directlyInside: root)
  }

  private static func writeMarker(
    named filename: String,
    in root: URL,
    fileManager: FileManager
  ) throws {
    guard isSecureDirectory(root) else { throw AppMigrationError.unsafeMigrationState }
    let marker = root.appendingPathComponent(filename)
    if pathEntryExists(marker, fileManager: fileManager) {
      guard isManagedRegularFile(marker, directlyInside: root) else {
        throw AppMigrationError.unsafeMigrationState
      }
      return
    }
    try Data("1\n".utf8).write(to: marker, options: .atomic)
    guard isManagedRegularFile(marker, directlyInside: root) else {
      throw AppMigrationError.unsafeMigrationState
    }
  }

  private static func pathEntryExists(_ url: URL, fileManager: FileManager) -> Bool {
    fileManager.fileExists(atPath: url.path)
      || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private static func isSecureDirectory(_ url: URL) -> Bool {
    let candidate = url.standardizedFileURL
    guard candidate.resolvingSymlinksInPath().path == candidate.path,
      let values = try? candidate.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private static func isManagedRegularFile(_ url: URL, directlyInside directory: URL) -> Bool {
    let root = directory.standardizedFileURL
    let candidate = url.standardizedFileURL
    guard isSecureDirectory(root),
      candidate.deletingLastPathComponent() == root,
      candidate.resolvingSymlinksInPath().path == candidate.path,
      let values = try? candidate.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }
}

private enum AppMigrationError: LocalizedError {
  case unsafeMigrationState

  var errorDescription: String? {
    "The app-data migration state is unsafe or unavailable."
  }
}
