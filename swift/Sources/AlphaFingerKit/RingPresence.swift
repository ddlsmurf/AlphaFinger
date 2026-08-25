import Foundation

/// Whether the ring counts as nearby.
///
/// Lives here rather than in the UI so it can be tested. The rule is only as good
/// as the timestamp it is given: that must be written **when an advertisement
/// arrives** and nowhere else. It previously doubled as the scan watchdog's seed,
/// and because the watchdog restarts the scan every ten seconds the value was
/// never stale — so this returned true from launch, in sessions where no ring was
/// ever heard.
public enum RingPresence {
  /// The ring advertises several times a second while awake, so a minute of
  /// silence means it has gone rather than that a packet was missed.
  public static let nearbyWindow: TimeInterval = 60

  public static func isNearby(lastHeard: Date?, now: Date = Date()) -> Bool {
    guard let lastHeard, lastHeard != .distantPast else { return false }
    return now.timeIntervalSince(lastHeard) < nearbyWindow
  }
}
