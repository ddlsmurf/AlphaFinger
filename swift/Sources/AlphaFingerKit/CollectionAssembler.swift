import Foundation

/// One complete multipart run: everything the ring stored for a single button
/// press, in index order.
public struct CollectionGroup: Sendable {
  public let startIndex: UInt32
  public let collections: [RingCollection]

  public var indices: [UInt32] { collections.map(\.index) }
  public var lastIndex: UInt32 { collections.map(\.index).max() ?? startIndex }

  /// The ring says so itself; a lone collection is not part of a run.
  public var isMultiPart: Bool {
    collections.contains { $0.multipartInfo?.isMultiPart == true }
  }

  /// Highest button count seen across the run.
  ///
  /// The count rises within a press burst — a double tap reports 1 then 2 — so
  /// the maximum is the number of presses in the gesture.
  public var buttonCount: UInt32 {
    collections.compactMap { $0.buttonPress?.count }.max() ?? 0
  }

  /// The most complete press record in the run.
  ///
  /// Parts report the burst as it stood when each was written, so the last one to
  /// see the most presses is the authoritative account of the gesture.
  public var buttonPress: ButtonPressSequence? {
    collections.compactMap(\.buttonPress).max { $0.count < $1.count }
  }

  public var ringTimestamp: Date? {
    collections.compactMap(\.ringTimestamp).min()
  }

  public var batteryMilliVolts: UInt16? {
    collections.compactMap(\.batteryMilliVolts).first
  }

  public var deviceIdentifier: String? {
    collections.compactMap(\.deviceIdentifier).first
  }

  public var lifetimeCollectionCount: UInt32? {
    collections.compactMap(\.lifetimeCollectionCount).max()
  }

  public var platformVersions: String? {
    collections.compactMap(\.platformVersions).first
  }

  /// Decodes every audio record in the run as one continuous stream.
  ///
  /// Centring spans the whole run: doing it per part would put a step at each
  /// boundary. See `RiceDecoder.pcm`.
  public func audio() throws -> AudioTimeline? {
    var parts: [QuantisedAudio] = []
    for collection in collections {
      for record in collection.compressedAudio {
        parts.append(try RiceDecoder.decodeQuantised(payload: record.payload))
      }
    }
    guard !parts.isEmpty else { return nil }
    return try RiceDecoder.pcm(parts)
  }

  /// Zero when there is no audio or it cannot be decoded -- the classifier reads
  /// this as "not a recording", which is the safe direction: a failed decode
  /// should not be filed as a recording.
  public func durationSeconds() -> Double {
    guard let audio = (try? audio()) ?? nil, audio.sampleRateHz > 0 else { return 0 }
    return Double(audio.samples.count) / Double(audio.sampleRateHz)
  }
}

/// Collects incoming collections into complete multipart runs.
///
/// A run is closed when a part marked `isFinalPart` arrives. Collections that
/// carry no multipart record, or are marked final immediately, close at once.
public final class CollectionAssembler {
  /// A run that has not seen its final part within this many collections is
  /// flushed anyway, so a lost part cannot wedge the pipeline forever.
  public static let maximumPartsPerRun = 512

  private var pending: [UInt32: [RingCollection]] = [:]
  private var order: [UInt32] = []
  private var highestAccepted: UInt32?
  /// When each open run last gained a part, for the stall rule.
  private var lastPartAt: [UInt32: Date] = [:]
  private let now: () -> Date

  /// `now` is injectable so the stall rule can be tested without waiting.
  public init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  /// Feeds one collection in. Returns any runs that became complete.
  public func accept(_ collection: RingCollection) -> [CollectionGroup] {
    let key = collection.multipartStartIndex

    // The same collection is routinely delivered twice: the cursor only advances
    // once a whole recording is filed, so every reconnection re-reads the run from
    // its start. Ignoring the repeat is what keeps one recording in one file --
    // treating a lower index as a restart instead used to close the run early and
    // split it in two.
    if pending[key]?.contains(where: { $0.index == collection.index }) == true {
      return []
    }

    if pending[key] == nil { order.append(key) }
    pending[key, default: []].append(collection)
    lastPartAt[key] = now()
    highestAccepted = max(collection.index, highestAccepted ?? collection.index)

    let info = collection.multipartInfo
    let isComplete = info == nil || info?.isFinalPart == true
    let isOverlong = (pending[key]?.count ?? 0) >= Self.maximumPartsPerRun
    guard isComplete || isOverlong else { return [] }
    return [close(key)].compactMap { $0 }
  }

  /// Drops the index baseline after a ring reset has been handled.
  public func ringDidReset() {
    highestAccepted = nil
  }

  /// Closes every open run, complete or not. Used when a source ends.
  public func flush() -> [CollectionGroup] {
    order.compactMap { close($0) }
  }

  /// Closes only runs that have not gained a part for `interval`.
  ///
  /// A recording is fetched across several connections, so an open run is normal
  /// between batches. This exists solely so a run whose final part never arrives
  /// is eventually written instead of being held until the process exits.
  public func flushRunsIdle(longerThan interval: TimeInterval) -> [CollectionGroup] {
    let deadline = now().addingTimeInterval(-interval)
    let stalled = order.filter { (lastPartAt[$0] ?? .distantPast) < deadline }
    return stalled.compactMap { close($0) }
  }

  private func close(_ key: UInt32) -> CollectionGroup? {
    guard let collections = pending.removeValue(forKey: key) else { return nil }
    order.removeAll { $0 == key }
    lastPartAt[key] = nil
    return CollectionGroup(startIndex: key,
                           collections: collections.sorted { $0.index < $1.index })
  }
}

/// What a completed run actually means, once classified.
public enum RingEvent: Sendable {
  /// A recording. `presses` is the full gesture that produced it, so a recording
  /// preceded by a tap is distinguishable from a plain one.
  case recording(CollectionGroup, presses: ButtonPressSequence?, reason: ClassificationReason)
  /// A press burst with no recording. `tapCount` is how many taps.
  ///
  /// Carries the battery reading because a gesture has no group behind it by the
  /// time it reaches a command, and it is the only chance to pass one on.
  case gesture(tapCount: UInt32, at: Date?, startIndex: UInt32,
               batteryMilliVolts: UInt16?, reason: ClassificationReason)
}

/// Which signal decided a classification.
///
/// Recorded and surfaced so an approximate answer never looks like a precise one:
/// if the fallback ran, the logs say so.
public enum ClassificationReason: String, Sendable {
  /// The ring's own press record said so. Precise.
  case pressRecord
  /// No usable press record; decided on decoded audio duration. Approximate.
  case durationFallback
}

/// Decides whether a run is a recording or a bare gesture.
///
/// The ring states the gesture outright — a **long** press is a recording, short
/// presses are taps — so that is what decides it. The duration threshold is only
/// a fallback for a collection whose press record is missing or malformed, and
/// when it runs the result is tagged `durationFallback` so nobody mistakes an
/// estimate for the ring's own word.
///
/// The fallback threshold sits in the gap observed in real use: recordings ran
/// 2.2–3.2 s, taps 0.001–0.107 s. Taps *do* carry a little audio, which is why
/// duration was never a good primary test.
public struct RecordingClassifier {
  public static let defaultThresholdSeconds = 0.5

  public let thresholdSeconds: Double

  public init(thresholdSeconds: Double = defaultThresholdSeconds) {
    self.thresholdSeconds = thresholdSeconds
  }

  public func classify(_ group: CollectionGroup) -> RingEvent {
    if let press = group.buttonPress, press.presses != nil, press.count > 0 {
      if press.containsRecording {
        return .recording(group, presses: press, reason: .pressRecord)
      }
      return .gesture(tapCount: press.tapCount, at: group.ringTimestamp,
                      startIndex: group.startIndex,
                      batteryMilliVolts: group.batteryMilliVolts,
                      reason: .pressRecord)
    }

    // No usable press record: fall back to shape and duration, and say so.
    let looksLikeRecording = group.isMultiPart
      || group.durationSeconds() >= thresholdSeconds
    guard looksLikeRecording else {
      return .gesture(tapCount: max(group.buttonCount, 1), at: group.ringTimestamp,
                      startIndex: group.startIndex,
                      batteryMilliVolts: group.batteryMilliVolts,
                      reason: .durationFallback)
    }
    return .recording(group, presses: group.buttonPress, reason: .durationFallback)
  }
}
