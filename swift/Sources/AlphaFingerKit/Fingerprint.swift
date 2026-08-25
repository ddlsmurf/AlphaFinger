import Foundation

/// Interpretation of the 32-bit state fingerprint carried in every advertisement.
///
/// The tests the ring's own firmware applies to this value.
/// Carried in every advertisement, so it can be read without connecting.
public enum RingFingerprint {
  /// Ring is in failsafe mode.
  public static let failsafe: UInt32 = 0xDEAD_DEAD
  /// Ring is running production-test firmware.
  public static let productionTest: UInt32 = 0xDEAD_BEEF

  /// Only the low 16 bits participate in the no-user and user-ID tests.
  public static let userMatchMask: UInt32 = 0xFFFF

  public static func isFailsafe(_ fingerprint: UInt32) -> Bool {
    fingerprint == failsafe
  }

  public static func isProductionTest(_ fingerprint: UInt32) -> Bool {
    fingerprint == productionTest
  }

  /// An unprogrammed ring: low 16 bits are all ones.
  public static func hasNoUser(_ fingerprint: UInt32) -> Bool {
    fingerprint & userMatchMask == userMatchMask
  }
}

/// Robert Jenkins' 32-bit integer hash, as used by
/// the user-ID test.
///
/// All six constants below appear verbatim in the disassembly.
public enum JenkinsHash32 {
  public static func mix(_ input: UInt32) -> UInt32 {
    var a = input
    a = (a &+ 0x7ED5_5D16) &+ (a << 12)
    a = (a ^ 0xC761_C23C) ^ (a >> 19)
    a = (a &+ 0x1656_67B1) &+ (a << 5)
    a = (a &+ 0xD3A2_646C) ^ (a << 9)
    a = (a &+ 0xFD70_46C5) &+ (a << 3)
    a = (a ^ 0xB55A_4F09) ^ (a >> 16)
    return a
  }
}

/// Maps a user ID onto the 16 bits the ring advertises.
///
/// **Unverified.** The per-word mixing above is confirmed, but the words are folded
/// the 33 word results together with NEON code whose exact order has not been
/// pinned down. `userIdMatches` therefore reflects the most likely reading (XOR
/// fold) and must be checked against a ring with a known user ID before it is
/// trusted. `AlphaFingerCLI`'s `check-fingerprint` command exists to do that.
public enum RingUserId {
  /// The ID is copied into a zero-filled 132-byte buffer.
  public static let bufferLength = 132
  public static let wordCount = bufferLength / 4

  public static func paddedBuffer(for userId: String) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: bufferLength)
    for (index, byte) in Array(userId.utf8).prefix(bufferLength).enumerated() {
      buffer[index] = byte
    }
    return buffer
  }

  /// Low 16 bits of the folded hash. See the caveat on this type.
  public static func fingerprintBits(for userId: String) -> UInt16 {
    let buffer = paddedBuffer(for: userId)
    var folded: UInt32 = 0
    for wordIndex in 0 ..< wordCount {
      let base = wordIndex * 4
      let word = UInt32(buffer[base]) | UInt32(buffer[base + 1]) << 8
        | UInt32(buffer[base + 2]) << 16 | UInt32(buffer[base + 3]) << 24
      folded ^= JenkinsHash32.mix(word)
    }
    return UInt16(truncatingIfNeeded: folded ^ (folded >> 16))
  }

  public static func matches(fingerprint: UInt32, userId: String) -> Bool {
    UInt16(truncatingIfNeeded: fingerprint) == fingerprintBits(for: userId)
  }
}
