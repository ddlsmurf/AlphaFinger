import Foundation

/// Decides whether an advertisement is worth connecting to.
///
/// The ring drops an idle link after about ten seconds, so a client that
/// reconnects on every drop holds the radio open almost continuously. A client
/// that waits to be asked is connected around 32% of the time instead, with gaps
/// of 14 and 18 seconds while the ring has nothing pending.
///
/// The asking is the advertisement's `needsServicing` bit. In the capture it goes
/// true, and it clears once a central connects -- so it is a signal to *start* a
/// connection, never a reason to keep one. A connected peripheral must wake at every connection interval whether or
/// not there is traffic; the ring advertises regardless. Staying away is free,
/// staying connected is not.
public struct ConnectionGate: Sendable {
  public enum Decision: Equatable, Sendable {
    case connect(reason: String)
    case stayAway

    public var shouldConnect: Bool {
      if case .connect = self { return true }
      return false
    }
  }

  /// What the caller knows about this ring already.
  public struct History: Sendable {
    /// Advertised collection count at the last successful fetch, if any.
    public var lastFetchedCount: UInt8?
    /// When a fetch last succeeded. Nil means never.
    public var lastFetchedAt: Date?

    public init(lastFetchedCount: UInt8? = nil, lastFetchedAt: Date? = nil) {
      self.lastFetchedCount = lastFetchedCount
      self.lastFetchedAt = lastFetchedAt
    }
  }

  public init() {}

  public func decide(advertisement: RingAdvertisement, history: History) -> Decision {
    // The ring asking is the whole point; everything below is a backstop.
    if advertisement.needsServicing {
      return .connect(reason: "the ring asked (needsServicing)")
    }
    // A nil count means we fetched without ever seeing an advertisement -- the
    // launch path connects to a remembered peripheral directly. That is not the
    // same as never having fetched, so it must not force a connection.
    guard let lastCount = history.lastFetchedCount else {
      return history.lastFetchedAt == nil
        ? .connect(reason: "nothing fetched from this ring yet")
        : .stayAway
    }
    // A count that differs means collections we have not seen.
    //
    // This is a standing difference, not an edge, and that is what makes a timed
    // safety net unnecessary: if a `needsServicing` flag is missed, every later
    // advertisement still shows a count that differs from the stored one, so the
    // next one we see connects. Compared with `!=` rather than `>` because a ring
    // reset counts *backwards* -- being wrong about a reset costs one connection,
    // missing one costs every recording on the ring.
    //
    // Residual gap, accepted: the count is a u8. If it wrapped through exactly 256
    // collections back to the stored value while we saw no advertisements at all,
    // this would not fire -- though `needsServicing` still would.
    if advertisement.rawCollectionCount != lastCount {
      return .connect(reason: "collection count changed "
                      + "\(lastCount) -> \(advertisement.rawCollectionCount)")
    }
    return .stayAway
  }
}
