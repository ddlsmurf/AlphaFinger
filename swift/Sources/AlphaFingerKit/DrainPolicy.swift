import Foundation

/// Decides whether to keep fetching on the current connection or hang up.
///
/// Draining the window and hanging up while the ring is *still recording* is the
/// expensive mistake: in `2026-08-24T060409Z` it cost **59 seconds** to reconnect,
/// against 0.5–1.9 s for every other connect that day. The ring only ever serves
/// completed collections -- `rangeEnd` is exclusive and reading it returns status
/// 67 -- so an empty window during a recording means "nothing *yet*", not
/// "nothing more".
public struct DrainPolicy: Sendable {
  /// Longest a single connection may be held open.
  ///
  /// Load-bearing, not a safety net: a ring that never sends a final part would
  /// otherwise hold the link forever, and holding it is the thing this whole
  /// design is trying to spend sparingly.
  public static let maximumHold: TimeInterval = 120
  /// Most window re-reads in one connection, as a second bound on the same thing.
  public static let maximumRounds = 60
  /// Pause between re-reads while waiting for the ring to produce more.
  public static let pollPause: TimeInterval = 0.4

  public struct State: Sendable {
    /// True when the last collection fetched was a multipart part that was not
    /// the final one -- i.e. the ring is still recording.
    public var recordingInProgress: Bool
    /// True when the window grew during this round.
    public var windowGrew: Bool
    public var rounds: Int
    public var elapsed: TimeInterval

    public init(recordingInProgress: Bool, windowGrew: Bool,
                rounds: Int, elapsed: TimeInterval) {
      self.recordingInProgress = recordingInProgress
      self.windowGrew = windowGrew
      self.rounds = rounds
      self.elapsed = elapsed
    }
  }

  public enum Decision: Equatable, Sendable {
    case keepDraining(reason: String)
    case hangUp(reason: String)

    public var shouldKeepDraining: Bool {
      if case .keepDraining = self { return true }
      return false
    }
  }

  public init() {}

  public func decide(_ state: State) -> Decision {
    if state.elapsed >= Self.maximumHold {
      return .hangUp(reason: String(format: "held for %.0fs", state.elapsed))
    }
    if state.rounds >= Self.maximumRounds {
      return .hangUp(reason: "\(state.rounds) rounds without finishing")
    }
    if state.recordingInProgress {
      return .keepDraining(reason: "the ring is still recording")
    }
    if state.windowGrew {
      return .keepDraining(reason: "more collections appeared")
    }
    return .hangUp(reason: "nothing left to collect")
  }
}
