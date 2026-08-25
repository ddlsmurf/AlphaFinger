import Foundation
import SwiftUI
import AlphaFingerKit

/// How much the Debug window shows.
///
/// This governs the **window only** — the JSONL capture on disk is always
/// complete. Choosing a low level can therefore never lose evidence after the
/// fact, which is the whole point: "it was set to off when the bug happened" is
/// designed out.
enum DebugVerbosity: String, CaseIterable, Identifiable {
  case off, normal, verbose, trace
  var id: String { rawValue }
  var label: String { rawValue.capitalized }

  /// True when a message tagged `level` should appear at this setting.
  func includes(_ level: DebugVerbosity) -> Bool {
    let order: [DebugVerbosity] = [.off, .normal, .verbose, .trace]
    guard let mine = order.firstIndex(of: self),
          let theirs = order.firstIndex(of: level) else { return false }
    return self != .off && theirs <= mine
  }

  var description: String {
    switch self {
    case .off: return "nothing in the window; the capture file still records all"
    case .normal: return "connections, recordings, commands, errors"
    case .verbose: return "adds Telesto exchanges, record breakdowns, decisions"
    case .trace: return "adds raw payload hex"
    }
  }
}

/// User settings, persisted in `UserDefaults`.
///
/// Folders are stored as security-scoped bookmarks rather than paths: a plain
/// path chosen today stops being readable after a restart under App Sandbox, and
/// silently failing to write recordings would be the worst possible failure mode.
@MainActor
final class AppSettings: ObservableObject {
  private enum Key {
    static let recordingsBookmark = "recordingsBookmark"
    static let thresholdSeconds = "recordingThresholdSeconds"
    static let pollSeconds = "pollIntervalSeconds"
    static let command = "command"
    /// Superseded by `command`. Read once so an existing setting survives the
    /// rename; never written again.
    static let legacyPostRecordingCommand = "postRecordingCommand"
    static let verbosity = "debugVerbosity"
    static let knownRingIdentifier = "knownRingIdentifier"
    /// How far through this ring's collections the app has got, and which ring
    /// that is. Read and written by `DefaultsCollectionCursor`, named here so the
    /// domain's keys are all in one place.
    static let cursorRing = "cursorRing"
    static let cursorIndex = "cursorIndex"
    static let notifyOnRecording = "notifyOnRecording"
  }

  static let defaultPollSeconds = 20.0

  /// Where recordings go until the user chooses somewhere else.
  ///
  /// Deliberately **not** created here. `RecordingWriter.write` already creates its
  /// destination, so the folder appears when the first recording is filed rather
  /// than the first time the app is launched -- an app that litters ~/Documents
  /// just for having been opened is a nuisance.
  static let defaultRecordingsDirectory: URL =
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AlphaFingerRecordings", isDirectory: true)

  @Published var recordingsDirectory: URL? {
    didSet { store(recordingsDirectory, as: Key.recordingsBookmark) }
  }
  /// The one command, run after a filed recording and after taps alike.
  @Published var command: String {
    didSet { defaults.set(command, forKey: Key.command) }
  }
  /// Notify when a recording has been filed. On by default, because the
  /// notification dismisses itself after a few seconds and is the only sign the
  /// app gives that it did its job. A failing command always notifies, whatever
  /// this says, and that one stays put.
  @Published var notifyOnRecording: Bool {
    didSet { defaults.set(notifyOnRecording, forKey: Key.notifyOnRecording) }
  }

  /// The ring we last connected to.
  ///
  /// Persisted so a restart can reconnect straight to it instead of scanning:
  /// CoreBluetooth keeps a `connect()` pending until the peripheral reappears,
  /// which reconnects in milliseconds.
  @Published var knownRingIdentifier: UUID? {
    didSet {
      defaults.set(knownRingIdentifier?.uuidString, forKey: Key.knownRingIdentifier)
    }
  }
  /// Set when a setting could not be persisted, so the failure is visible instead
  /// of the app quietly appearing unconfigured.
  ///
  /// Kept to one short sentence: this is rendered as a menu item, and a menu whose
  /// width is set by a file path plus an NSError description is unusable. The
  /// detail belongs in the debug window.
  @Published var lastError: String?

  /// Whether the recordings folder exists yet. It is created when the first
  /// recording is filed, so "not there" is a normal state, not a fault.
  var recordingsDirectoryExists: Bool {
    guard let url = recordingsDirectory else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }
  @Published var verbosity: DebugVerbosity {
    didSet { defaults.set(verbosity.rawValue, forKey: Key.verbosity) }
  }
  @Published var thresholdSeconds: Double {
    didSet { defaults.set(thresholdSeconds, forKey: Key.thresholdSeconds) }
  }
  @Published var pollSeconds: Double {
    didSet { defaults.set(pollSeconds, forKey: Key.pollSeconds) }
  }

  private let defaults = UserDefaults.standard

  init() {
    // Falls back to the old key so a command configured before the two fields
    // became one is still there afterwards, rather than silently emptying.
    command = defaults.string(forKey: Key.command)
      ?? defaults.string(forKey: Key.legacyPostRecordingCommand) ?? ""
    verbosity = DebugVerbosity(rawValue: defaults.string(forKey: Key.verbosity) ?? "")
      ?? .normal
    let threshold = defaults.double(forKey: Key.thresholdSeconds)
    thresholdSeconds = threshold > 0 ? threshold : RecordingClassifier.defaultThresholdSeconds
    let poll = defaults.double(forKey: Key.pollSeconds)
    pollSeconds = poll > 0 ? poll : Self.defaultPollSeconds
    // Falling back to the default means the app is configured out of the box and
    // starts on its own; there is nothing a first-time user must do first.
    let stored = defaults.data(forKey: Key.recordingsBookmark)
    if let resolved = Self.resolve(stored) {
      recordingsDirectory = resolved
    } else {
      recordingsDirectory = Self.defaultRecordingsDirectory
      // Drop a bookmark that no longer points anywhere usable, so it cannot be
      // resolved again next launch.
      if stored != nil {
        defaults.removeObject(forKey: Key.recordingsBookmark)
        lastError = "Recordings folder was missing — using the default again"
      }
    }
    // `bool(forKey:)` returns false for a key that has never been set, which
    // would make the default off. Check for the key itself so a fresh install
    // gets true and an explicit "off" is still honoured.
    notifyOnRecording = defaults.object(forKey: Key.notifyOnRecording) as? Bool ?? true
    knownRingIdentifier = defaults.string(forKey: Key.knownRingIdentifier)
      .flatMap(UUID.init(uuidString:))
  }

  /// Everything needed before the app can file anything.
  var isConfigured: Bool { recordingsDirectory != nil }

  var pipelineSettings: RingPipelineSettings? {
    guard let recordings = recordingsDirectory else { return nil }
    return RingPipelineSettings(
      recordingsDirectory: recordings,
      command: command,
      recordingThresholdSeconds: thresholdSeconds)
  }

  /// Persists a folder choice as a bookmark, so it survives the folder being
  /// moved or renamed.
  ///
  /// A plain bookmark, **not** `.withSecurityScope`: that is a sandbox facility
  /// and this app has no sandbox entitlement, so requesting it can fail. When it
  /// did, the old code's `try?` yielded nil and `defaults.set(nil,)` **deleted the
  /// key** -- silently forgetting the configured folder and leaving the app
  /// looking unconfigured with no explanation.
  private func store(_ url: URL?, as key: String) {
    guard let url else { return defaults.removeObject(forKey: key) }
    do {
      let bookmark = try url.bookmarkData(includingResourceValuesForKeys: nil,
                                          relativeTo: nil)
      defaults.set(bookmark, forKey: key)
      lastError = nil
    } catch {
      // Keep whatever was stored before: losing the setting is worse than an
      // out-of-date bookmark, and the path still works for this session.
      lastError = "Could not remember that folder — it may reset on restart"
    }
  }

  /// Resolves a stored bookmark, accepting either form, and refusing a target
  /// that has been thrown away.
  ///
  /// Bookmarks written by earlier builds carry a security scope, so both are
  /// tried. A security-scoped URL needs `startAccessingSecurityScopedResource`;
  /// a plain one must not have it called.
  ///
  /// **A bookmark follows its folder when the folder moves** -- that is the point
  /// of one -- including into the Trash. Left unchecked, deleting the recordings
  /// folder silently redirects every future recording into `~/.Trash`, where
  /// emptying the Trash destroys them. A trashed target is treated as no target,
  /// so the caller falls back to the default.
  private static func resolve(_ bookmark: Data?) -> URL? {
    guard let bookmark else { return nil }
    var isStale = false
    var resolved = try? URL(resolvingBookmarkData: bookmark, relativeTo: nil,
                            bookmarkDataIsStale: &isStale)
    if resolved == nil {
      var staleScoped = false
      if let scoped = try? URL(resolvingBookmarkData: bookmark,
                               options: .withSecurityScope,
                               relativeTo: nil,
                               bookmarkDataIsStale: &staleScoped) {
        _ = scoped.startAccessingSecurityScopedResource()
        resolved = scoped
      }
    }
    guard let url = resolved, !isInTrash(url) else { return nil }
    return url
  }

  /// Shared with the writer, which refuses to file into the Trash as a last
  /// line of defence.
  static func isInTrash(_ url: URL) -> Bool { RecordingWriter.isInTrash(url) }
}
