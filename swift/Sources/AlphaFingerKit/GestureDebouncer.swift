import Foundation

/// A press burst, after the individual presses have been merged.
public struct RingGesture: Equatable, Sendable {
  /// Number of presses: 1 for a tap, 2 for a double tap.
  public let count: UInt32
  /// Ring-side time of the burst, from the first press.
  public let timestamp: Date?
  public let startIndex: UInt32
  /// As the ring reported it alongside the presses, when it did.
  public var batteryMilliVolts: UInt16?
}

/// Merges the ring's per-press collections into single gestures.
///
/// The ring reports **each press as its own collection**, with a running count —
/// an observed double tap arrives as two collections sharing a timestamp with
/// counts 1 then 2. Acting on the first would fire a single-tap action every time
/// someone double taps, so the presses have to be coalesced and the highest count
/// taken.
///
/// This is the job a button-sequence debouncer did before it was
/// removed from the library in `6970c84`; its constants, recovered from the
/// earlier build, are reused here. Its own documentation explains the design:
///
/// > Debounces decoded button sequences from ring collection transfers, so the
/// > phone doesn't act on `[short short]` when `[short short short]` is about to
/// > arrive. The debounce clock starts at the ring-side button release, not
/// > phone-side arrival — delivery takes seconds […]
///
/// Which is why the clock here runs on the ring's timestamps, not on when the
/// collection happened to reach us.
public final class GestureDebouncer {
  /// Gap after a press within which another press extends the same gesture.
  public static let debounceWindow: TimeInterval = 0.7
  /// Maximum gap between presses of one gesture. Ring release stamps have 1 s
  /// resolution, so this is generous.
  public static let sameGestureMaxGap: TimeInterval = 3.0
  /// Gestures older than this are dropped rather than acted on — a stale burst
  /// surfacing after a long disconnection should not fire an action.
  public static let stalenessThreshold: TimeInterval = 30.0

  private var pending: RingGesture?
  private let onGesture: (RingGesture) -> Void
  private let now: () -> Date

  /// `now` is injectable so tests can drive the staleness rule deterministically.
  public init(now: @escaping () -> Date = Date.init,
              onGesture: @escaping (RingGesture) -> Void) {
    self.now = now
    self.onGesture = onGesture
  }

  /// Feeds one bare-gesture event in.
  ///
  /// Presses close together in ring time collapse into one gesture; a press far
  /// from the pending one flushes it first.
  public func accept(count: UInt32, at timestamp: Date?, startIndex: UInt32,
                     batteryMilliVolts: UInt16? = nil) {
    let candidate = RingGesture(count: count, timestamp: timestamp,
                                startIndex: startIndex,
                                batteryMilliVolts: batteryMilliVolts)

    guard let current = pending else {
      pending = candidate
      return
    }

    if Self.belongTogether(current, candidate) {
      // Same burst: keep the earliest identity, take the highest count.
      pending = RingGesture(count: max(current.count, candidate.count),
                            timestamp: current.timestamp ?? candidate.timestamp,
                            startIndex: min(current.startIndex, candidate.startIndex),
                            batteryMilliVolts: current.batteryMilliVolts
                              ?? candidate.batteryMilliVolts)
    } else {
      emit(current)
      pending = candidate
    }
  }

  /// Emits any pending gesture. Call when nothing more is coming that could
  /// extend or absorb it — the ring reporting itself idle, or shutdown.
  public func flush() {
    guard let current = pending else { return }
    pending = nil
    emit(current)
  }

  /// Drops a pending gesture that a recording has turned out to account for.
  ///
  /// The ring stores a press as its own collection as soon as it ends, so a tap
  /// followed by a press-and-hold arrives as a bare tap first and the recording
  /// afterwards — and that recording's own press record already carries the tap
  /// ("short+long", tap count 1). Emitting the bare tap as well runs the command
  /// twice for one gesture. Returns whether it absorbed anything, so the caller
  /// can say so in the log.
  @discardableResult
  public func discardPending(absorbedBy recordingStartIndex: UInt32,
                             at timestamp: Date?) -> Bool {
    guard let current = pending else { return false }
    let recording = RingGesture(count: 0, timestamp: timestamp,
                                startIndex: recordingStartIndex,
                                batteryMilliVolts: nil)
    guard Self.belongTogether(current, recording) else { return false }
    pending = nil
    return true
  }

  /// Whether a held gesture has been waiting longer than `age`.
  ///
  /// The release signal is an advertisement saying the ring is idle, and a ring
  /// that goes out of range stops sending those. This is the backstop: held past
  /// the point where a recording could still absorb it, a gesture is let go
  /// rather than waiting for a signal that may never arrive.
  public func hasPendingOlderThan(_ age: TimeInterval) -> Bool {
    guard let pending else { return false }
    guard let timestamp = pending.timestamp else { return true }
    return now().timeIntervalSince(timestamp) > age
  }

  private func emit(_ gesture: RingGesture) {
    if let timestamp = gesture.timestamp,
       now().timeIntervalSince(timestamp) > Self.stalenessThreshold {
      // Dropped deliberately: acting on a gesture from minutes ago is worse than
      // doing nothing. Callers see this in the capture log, not as an error.
      return
    }
    onGesture(gesture)
  }

  static func belongTogether(_ a: RingGesture, _ b: RingGesture) -> Bool {
    // Consecutive collection indices are the strongest signal that two presses
    // came from one burst; the ring numbers them in order as it stores them.
    if b.startIndex == a.startIndex + 1 { return true }
    guard let first = a.timestamp, let second = b.timestamp else { return false }
    let gap = abs(second.timeIntervalSince(first))
    return gap <= sameGestureMaxGap
  }
}
