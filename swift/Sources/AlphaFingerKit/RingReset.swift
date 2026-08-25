import Foundation

/// Why we believe the ring restarted its collection numbering.
///
/// The two cases carry deliberately different authority. Advertisements are
/// unauthenticated broadcasts that anyone can transmit and the count they carry
/// is a single byte; the collection window is read over the bonded, encrypted
/// link in reply to our own request. Only the latter is allowed to destroy
/// persisted state.
public enum RingResetEvidence: Equatable, Sendable, CustomStringConvertible {
  /// Suspicion, from the air. Worth an early poll, never worth acting on.
  case advertisedCountFell(fingerprint: UInt32, previous: UInt8, now: UInt8)
  /// Proof, from the link.
  case collectionWindowFell(rangeEnd: UInt32, cursor: UInt32)

  /// Whether this is strong enough to invalidate the cursor.
  public var isConclusive: Bool {
    if case .collectionWindowFell = self { return true }
    return false
  }

  public var description: String {
    switch self {
    case let .advertisedCountFell(fingerprint, previous, now):
      return String(format: "advertised collection count fell %u -> %u "
                    + "for fingerprint 0x%08X", previous, now, fingerprint)
    case let .collectionWindowFell(rangeEnd, cursor):
      return "the ring's highest collection index is \(rangeEnd), below the "
        + "cursor at \(cursor); the ring restarted its numbering"
    }
  }
}

/// Detects a ring whose collection indices have restarted.
///
/// A reset is invisible to a client that only tracks its own position: indices
/// begin again at 0, every one of them compares as already seen, and the client
/// silently stops fetching for good. Observed in
/// a live session: on a reset the advertised count drops (11 -> 0)
/// while the fingerprint is unchanged and the bond survives -- so neither
/// re-pairing nor a fingerprint change can be used to spot it.
public final class RingResetDetector {
  /// How many consecutive lower sightings are needed before a fall in the
  /// advertised count is even reported as a suspicion. One malformed or spoofed
  /// advertisement should not be able to trigger a full refetch.
  public static let corroboratingSightings = 2

  private var fingerprint: UInt32?
  private var highestCount: UInt8?
  private var lowSightings = 0

  public init() {}

  /// Folds in one advertisement, returning a suspicion if the count fell.
  public func observe(_ advertisement: RingAdvertisement) -> RingResetEvidence? {
    let count = advertisement.rawCollectionCount
    defer { fingerprint = advertisement.stateFingerprint }

    // A different fingerprint is a different ring, or the same ring reprogrammed
    // for another user -- either way the previous count is not comparable.
    guard fingerprint == advertisement.stateFingerprint else {
      highestCount = count
      lowSightings = 0
      return nil
    }
    guard let previous = highestCount else {
      highestCount = count
      return nil
    }
    guard count < previous else {
      highestCount = count
      lowSightings = 0
      return nil
    }
    // rawCollectionCount is a u8 and the device's own
    // truncateCollectionCount rule as unverified, so a step down from the top of
    // the range is at least as likely to be a wrap as a reset.
    guard previous != UInt8.max else { return nil }

    lowSightings += 1
    guard lowSightings >= Self.corroboratingSightings else { return nil }
    lowSightings = 0
    highestCount = count
    return .advertisedCountFell(fingerprint: advertisement.stateFingerprint,
                                previous: previous, now: count)
  }

  /// Conclusive evidence, from the collection window the ring reports.
  ///
  /// `rangeEnd` is monotone for a given numbering: the ring's newest index only
  /// grows. Eviction moves `rangeStart` **forward** and is handled separately --
  /// checking `rangeStart` here would confuse the two and throw away good
  /// recordings.
  public static func evidence(rangeEnd: UInt32, cursor: UInt32?)
    -> RingResetEvidence? {
    guard let cursor, rangeEnd < cursor else { return nil }
    return .collectionWindowFell(rangeEnd: rangeEnd, cursor: cursor)
  }

  /// Forgets the advertisement baseline after a reset has been handled.
  public func ringDidReset() {
    highestCount = nil
    lowSightings = 0
  }
}
