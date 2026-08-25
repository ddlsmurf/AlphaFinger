import Foundation

/// Writes a recording to disk as a WAV plus a JSON sidecar.
///
/// The sidecar exists so an archived recording stays self-describing: the ring's
/// own timestamp, which collections it came from, the button count, battery and
/// firmware. Losing that would make a folder of WAVs much less useful later.
///
/// Files appear in the destination **atomically**. Everything is built in a
/// staging directory first and only moved into place once complete, so a process
/// watching the folder — or a person looking at it — never sees a half-written
/// WAV, and a crash mid-write leaves no debris in the archive.
public struct RecordingWriter {
  public struct Result: Sendable {
    public let audioURL: URL
    public let metadataURL: URL
    public let durationSeconds: Double
    public let sampleCount: Int
  }

  /// Filenames sort chronologically and survive every filesystem: no colons.
  static let fileNameFormat = "yyyy-MM-dd'T'HHmmss'Z'"

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = fileNameFormat
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  public init() {}

  /// Used when a group carries no `deviceId` record. Never observed in 362
  /// captured collections, but a missing id must not cost a recording.
  static let unknownDevice = "unknown-ring"

  /// `<ring time>-<device id>-tap<N>-<startIndex>.wav`, e.g.
  /// `2026-08-23T131852Z-a1b2c3d4e5f6-tap0-0308.wav`.
  ///
  /// Time leads so the folder sorts chronologically. The device id distinguishes
  /// rings. `tapN` is the number of **short** presses that preceded the recording:
  /// `tap0` is a plain long press, `tap1` is a tap-then-record. The start index
  /// disambiguates two recordings inside the same second, which the ring's
  /// 1-second timestamp resolution makes possible.
  public func fileNameStem(for group: CollectionGroup) -> String {
    let stamp = group.ringTimestamp.map(Self.formatter.string(from:)) ?? "unknown-time"
    let device = group.deviceIdentifier ?? Self.unknownDevice
    let taps = group.buttonPress?.tapCount ?? 0
    return String(format: "%@-%@-tap%u-%04d", stamp, device, taps, group.startIndex)
  }

  /// Writes the audio and its sidecar into `directory`, atomically.
  ///
  /// Throws rather than skipping if the group has no audio: a recording with
  /// nothing in it means the decode went wrong, and silently writing an empty
  /// file would hide that.
  @discardableResult
  public func write(_ group: CollectionGroup, to directory: URL,
                    gesture: String, pressPattern: String = "unknown",
                    classifiedBy: String = "pressRecord",
                    receivedAt: Date = Date()) throws -> Result {
    guard let audio = try group.audio(), !audio.samples.isEmpty else {
      throw AlphaFingerDecodeError.unsupported(
        "collection group \(group.startIndex) decoded to no audio "
        + "(\(counted(group.collections.count, "collection")), "
        + "\(group.collections.reduce(0) { $0 + $1.bytes.count }) bytes)")
    }

    // Last line of defence. A bookmark follows its folder into the Trash, so a
    // deleted recordings folder can silently redirect everything here; a recording
    // written to the Trash is destroyed the next time it is emptied, and cannot be
    // fetched from the ring again.
    guard !Self.isInTrash(directory) else {
      throw AlphaFingerDecodeError.unsupported(
        "refusing to write recordings into the Trash: \(directory.path)")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = try uniqueStem(fileNameStem(for: group), in: directory)
    let audioURL = directory.appendingPathComponent("\(stem).wav")
    let metadataURL = directory.appendingPathComponent("\(stem).json")
    let duration = Double(audio.samples.count) / Double(max(audio.sampleRateHz, 1))

    // A staging directory on the *same volume* as the destination, so moving is
    // a rename rather than a copy -- which is what makes it atomic. Foundation
    // picks the right place; a plain temporary directory could easily be on
    // another filesystem and would silently degrade to a non-atomic copy.
    let staging = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask,
      appropriateFor: directory, create: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    let stagedAudio = staging.appendingPathComponent("\(stem).wav")
    let stagedMetadata = staging.appendingPathComponent("\(stem).json")

    try WAVWriter.data(samples: audio.samples, sampleRateHz: audio.sampleRateHz)
      .write(to: stagedAudio)
    try metadata(for: group, audio: audio, gesture: gesture, pressPattern: pressPattern,
                 classifiedBy: classifiedBy, receivedAt: receivedAt,
                 duration: duration, audioFileName: audioURL.lastPathComponent)
      .write(to: stagedMetadata)

    // Sidecar first, audio second. Anything watching the folder for new `.wav`
    // files then always finds its metadata already present.
    try move(stagedMetadata, to: metadataURL)
    do {
      try move(stagedAudio, to: audioURL)
    } catch {
      // Otherwise the sidecar is left orphaned, describing a recording that is
      // not there.
      try? FileManager.default.removeItem(at: metadataURL)
      throw error
    }

    return Result(audioURL: audioURL, metadataURL: metadataURL,
                  durationSeconds: duration, sampleCount: audio.samples.count)
  }

  /// Whether a URL sits inside any Trash directory. Checked by path component as
  /// well as against the known trash directories, because a folder on another
  /// volume is trashed to `.Trashes` there rather than to the home one.
  public static func isInTrash(_ url: URL) -> Bool {
    let components = url.standardizedFileURL.pathComponents
    if components.contains(".Trash") || components.contains(".Trashes") { return true }
    let trashes = FileManager.default.urls(for: .trashDirectory, in: .allDomainsMask)
    return trashes.contains { url.standardizedFileURL.path.hasPrefix($0.path) }
  }

  /// The most recordings allowed to share one stem before we refuse.
  static let maximumStemCollisions = 100

  /// Finds a free stem, suffixing `-2`, `-3`, … if one is taken.
  ///
  /// The ring's timestamp has 1-second resolution, so two recordings can produce
  /// the same stem. Replacing the existing file loses a recording that cannot be
  /// fetched again -- which is exactly what happened when a run was split into
  /// per-collection fragments that all carried the same start index.
  private func uniqueStem(_ stem: String, in directory: URL) throws -> String {
    for attempt in 1 ... Self.maximumStemCollisions {
      let candidate = attempt == 1 ? stem : "\(stem)-\(attempt)"
      let audio = directory.appendingPathComponent("\(candidate).wav")
      if !FileManager.default.fileExists(atPath: audio.path) { return candidate }
    }
    throw AlphaFingerDecodeError.unsupported(
      "\(Self.maximumStemCollisions) recordings already share the stem '\(stem)' in "
      + "\(directory.path); refusing to add another rather than overwrite one")
  }

  /// Moves into place, never over an existing file.
  private func move(_ source: URL, to destination: URL) throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw AlphaFingerDecodeError.unsupported(
        "refusing to overwrite \(destination.path): a recording already there "
        + "cannot be fetched from the ring again")
    }
    try FileManager.default.moveItem(at: source, to: destination)
  }

  private func metadata(for group: CollectionGroup, audio: AudioTimeline,
                        gesture: String, pressPattern: String, classifiedBy: String,
                        receivedAt: Date, duration: Double,
                        audioFileName: String) throws -> Data {
    var metadata: [String: Any] = [
      "gesture": gesture,
      "pressPattern": pressPattern,
      "classifiedBy": classifiedBy,
      "receivedAt": Self.isoFormatter.string(from: receivedAt),
      "startIndex": Int(group.startIndex),
      "collectionIndices": group.indices.map(Int.init),
      "isMultiPart": group.isMultiPart,
      "buttonCount": Int(group.buttonCount),
      "sampleRateHz": Int(audio.sampleRateHz),
      "sampleCount": audio.samples.count,
      "durationSeconds": duration,
      "audioFile": audioFileName,
    ]
    if let timestamp = group.ringTimestamp {
      metadata["ringTimestamp"] = Self.isoFormatter.string(from: timestamp)
      metadata["ringTimestampUnix"] = Int(timestamp.timeIntervalSince1970)
      // How long ago the ring says this was recorded. The ring holds elapsed time
      // and resolves it to absolute once the clock is set, so this stays accurate
      // however late the sync happened -- and an implausible value here is how a
      // wrong ring clock becomes visible instead of silently misdating files.
      metadata["ageAtReceiptSeconds"] = receivedAt.timeIntervalSince(timestamp)
    }
    if let battery = group.batteryMilliVolts { metadata["batteryMilliVolts"] = Int(battery) }
    if let lifetime = group.lifetimeCollectionCount {
      metadata["lifetimeCollectionCount"] = Int(lifetime)
    }
    if let versions = group.platformVersions { metadata["platformVersions"] = versions }

    return try JSONSerialization.data(withJSONObject: metadata,
                                      options: [.prettyPrinted, .sortedKeys])
  }
}

/// Remembers how far through the ring's collections the client has got.
///
/// The ring never forgets a collection on its own, and nothing here
/// erase them either — it just tracks its own position. So the client has to.
///
/// **The library does not persist this.** It defines only the shape; the
/// application supplies an implementation backed by whatever it already uses for
/// state. That keeps storage policy — file, defaults, database, synced — out of a
/// library whose job is decoding, and lets tests substitute something trivial.
///
/// The cursor must advance only once a recording is safely on disk, so an
/// interrupted save is retried rather than skipped.
public protocol CollectionCursor: AnyObject {
  /// Highest index known to be fully handled, or nil if none ever was.
  var lastCompletedIndex: UInt32? { get }

  /// Whether `index` has already been dealt with.
  func hasSeen(_ index: UInt32) -> Bool

  /// Advances the cursor. Implementations must never move it backwards.
  func markCompleted(throughIndex index: UInt32) throws

  /// Discards the position because the ring restarted its collection numbering.
  ///
  /// The only legal way for the cursor to move backwards, and deliberately
  /// **not** given a default implementation: a defaulted no-op would silently
  /// reinstate the bug this exists to fix, where a reset ring's indices all
  /// compare as already seen and the client stops fetching for good.
  func invalidate(reason: String) throws

  /// Ties the position to a ring, discarding it if it belongs to a different one.
  ///
  /// A position is a number in one ring's sequence and means nothing in another's:
  /// adopt a different ring while holding index 453 and every one of its
  /// collections below 453 reads as already handled, so the client fetches nothing
  /// and says nothing. Must be called before any fetching on a connection.
  ///
  /// Like `invalidate`, deliberately **not** given a default implementation. A
  /// defaulted no-op would silently reinstate exactly that.
  @discardableResult
  func adopt(ring: UUID) throws -> CursorAdoption
}

/// What `adopt` decided, so the caller can say which of the three happened.
public enum CursorAdoption: Equatable, Sendable {
  /// No ring was remembered; this one is now.
  case firstRing
  /// The same ring as before, so its position still applies.
  case resumed(fromIndex: UInt32?)
  /// A different ring. The old position has been discarded, and this one starts
  /// from its first collection.
  case differentRing(previous: UUID)

  public var description: String {
    switch self {
    case .firstRing:
      return "first ring seen; starting from its first collection"
    case let .resumed(index):
      return index.map { "same ring; resuming after collection \($0)" }
        ?? "same ring; nothing fetched from it yet"
    case let .differentRing(previous):
      return "a different ring (was \(previous.uuidString)); its position was "
        + "discarded and this one starts from its first collection"
    }
  }
}

public extension CollectionCursor {
  /// The obvious reading of `lastCompletedIndex`, so implementations only have to
  /// supply storage.
  func hasSeen(_ index: UInt32) -> Bool {
    guard let last = lastCompletedIndex else { return false }
    return index <= last
  }
}

/// A cursor that forgets everything when the process exits.
///
/// For tests, and for a one-shot replay where re-reading is harmless. Real use
/// wants a persistent implementation supplied by the application.
public final class InMemoryCollectionCursor: CollectionCursor {
  public private(set) var lastCompletedIndex: UInt32?
  private var ring: UUID?

  public init(lastCompletedIndex: UInt32? = nil) {
    self.lastCompletedIndex = lastCompletedIndex
  }

  public func markCompleted(throughIndex index: UInt32) throws {
    if let last = lastCompletedIndex, index <= last { return }
    lastCompletedIndex = index
  }

  public func invalidate(reason: String) throws {
    lastCompletedIndex = nil
  }

  @discardableResult
  public func adopt(ring newRing: UUID) throws -> CursorAdoption {
    defer { ring = newRing }
    guard let ring else { return .firstRing }
    guard ring != newRing else { return .resumed(fromIndex: lastCompletedIndex) }
    lastCompletedIndex = nil
    return .differentRing(previous: ring)
  }
}
