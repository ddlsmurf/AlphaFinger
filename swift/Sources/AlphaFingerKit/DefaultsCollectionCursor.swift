import Foundation

/// How far through one ring's collections the client has got, kept in
/// `UserDefaults` alongside everything else the app remembers about that ring.
///
/// It lived in a file next to the session logs, which gave it the wrong lifetime
/// in both directions: deleting the logs reset the position, and resetting the
/// settings left it behind describing a ring the app no longer knew.
///
/// The ring's identifier is stored with the index, because an index is a number in
/// one ring's sequence and means nothing in another's. See `adopt(ring:)`.
///
/// `UserDefaults` is injected so this is testable without touching the real
/// domain; the application passes `.standard`.
public final class DefaultsCollectionCursor: CollectionCursor {
  private let defaults: UserDefaults
  private let ringKey: String
  private let indexKey: String
  private let lock = NSLock()

  public init(defaults: UserDefaults = .standard,
              ringKey: String = "cursorRing",
              indexKey: String = "cursorIndex") {
    self.defaults = defaults
    self.ringKey = ringKey
    self.indexKey = indexKey
  }

  public var lastCompletedIndex: UInt32? {
    lock.lock()
    defer { lock.unlock() }
    return storedIndex
  }

  public func markCompleted(throughIndex newIndex: UInt32) throws {
    lock.lock()
    defer { lock.unlock() }
    if let current = storedIndex, newIndex <= current { return }
    defaults.set(Int(newIndex), forKey: indexKey)
  }

  /// Forgets the position and which ring it belonged to. Nothing on the ring
  /// changes; `reason` is the caller's to log.
  public func invalidate(reason: String) throws {
    lock.lock()
    defer { lock.unlock() }
    defaults.removeObject(forKey: indexKey)
    defaults.removeObject(forKey: ringKey)
  }

  @discardableResult
  public func adopt(ring newRing: UUID) throws -> CursorAdoption {
    lock.lock()
    defer { lock.unlock() }
    defer { defaults.set(newRing.uuidString, forKey: ringKey) }

    guard let stored = defaults.string(forKey: ringKey).flatMap(UUID.init(uuidString:))
    else {
      // No ring remembered. Any index lying around cannot be attributed to this
      // one, so it goes -- guessing is the failure this whole thing prevents.
      defaults.removeObject(forKey: indexKey)
      return .firstRing
    }
    guard stored != newRing else { return .resumed(fromIndex: storedIndex) }
    defaults.removeObject(forKey: indexKey)
    return .differentRing(previous: stored)
  }

  /// Adopts a position recovered from somewhere else, attributing it to `ring`.
  /// Refuses if a position is already stored: the existing one is authoritative.
  @discardableResult
  public func seed(index: UInt32, ring: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard storedIndex == nil else { return false }
    defaults.set(Int(index), forKey: indexKey)
    defaults.set(ring.uuidString, forKey: ringKey)
    return true
  }

  /// Caller holds the lock. Absent and negative both mean "no position": a
  /// missing key reads as 0 through `integer(forKey:)`, which would otherwise be
  /// indistinguishable from having handled collection 0.
  private var storedIndex: UInt32? {
    guard let number = defaults.object(forKey: indexKey) as? Int, number >= 0 else {
      return nil
    }
    return UInt32(number)
  }
}
