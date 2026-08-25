import Foundation

/// State the ring broadcasts without needing a connection.
///
/// The layout of the ring's manufacturer-specific advertising data.
/// Six bytes of manufacturer-specific data, broadcast continuously.
public struct RingAdvertisement: Equatable, Sendable {
  /// Identifies the ring's mode, or which user it is programmed for.
  /// See `RingFingerprint` for how to interpret it.
  public let stateFingerprint: UInt32
  /// As advertised. The device applies a truncation rule to this before using it
  /// before use; that rule has not been reversed, so this is the raw value.
  public let rawCollectionCount: UInt8
  public let isMoving: Bool
  public let needsServicing: Bool
  /// True while the ring's button is held -- it is recording.
  public let inCollectionState: Bool
  public let hasDebugInfo: Bool
  /// Bit 3 of the flags byte. The native parser extracts it and the JNI wrapper
  /// then discards it, so it is a real wire bit with no known consumer. Exposed
  /// rather than dropped so a capture can be checked against it.
  public let unknownFlagBit3: Bool

  /// Manufacturer-data lengths that are valid, and the offset the
  /// 6-byte payload starts at in each.
  ///
  /// CoreBluetooth hands you `kCBAdvDataManufacturerData` *including* the 2-byte
  /// company identifier, so on Apple platforms the 8-byte form is the one you
  /// see; Android strips the ID and sees 6.
  static let payloadOffsetsByLength: [Int: Int] = [6: 0, 8: 2]

  static let payloadLength = 6
  static let flagsOffset = 5
  static let collectionCountOffset = 4

  /// Core Devices' Bluetooth SIG company identifier, 3818.
  ///
  /// Advertisements are gated on this *after* the service-UUID scan filter:
  /// exactly one manufacturer-data block,
  /// this company, at least 6 payload bytes. Anything else is ignored.
  public static let companyIdentifier: UInt16 = 0x0EEA

  /// Whether manufacturer data as CoreBluetooth hands it over carries the ring's
  /// company identifier.
  ///
  /// Apple platforms include the 2-byte company ID, so this reads the prefix;
  /// the 6-byte Android form has no ID to check and is accepted on the basis
  /// that the caller already knows where it came from.
  public static func hasRingCompanyIdentifier(_ manufacturerData: [UInt8]) -> Bool {
    guard manufacturerData.count >= 2 + payloadLength else { return false }
    let identifier = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
    return identifier == companyIdentifier
  }

  private static let bitIsMoving: UInt8 = 7
  private static let bitNeedsServicing: UInt8 = 6
  private static let bitInCollectionState: UInt8 = 5
  private static let bitHasDebugInfo: UInt8 = 4
  private static let bitUnknown: UInt8 = 3

  /// Parses raw manufacturer data. Throws rather than returning nil so the
  /// caller learns *why* a payload was rejected. A parser that silently
  /// returns null for both wrong-length and malformed input.
  public init(manufacturerData: [UInt8]) throws {
    guard let base = Self.payloadOffsetsByLength[manufacturerData.count] else {
      throw AlphaFingerDecodeError.unexpectedLength(
        field: "advertisement manufacturer data",
        length: manufacturerData.count,
        expected: Self.payloadOffsetsByLength.keys.sorted())
    }
    let reader = ByteReader(manufacturerData)
    stateFingerprint = try reader.u32(at: base, "stateFingerprint")
    rawCollectionCount = try reader.u8(
      at: base + Self.collectionCountOffset, "collectionCount")
    let flags = try reader.u8(at: base + Self.flagsOffset, "flags")

    func bit(_ index: UInt8) -> Bool { (flags >> index) & 1 == 1 }
    isMoving = bit(Self.bitIsMoving)
    needsServicing = bit(Self.bitNeedsServicing)
    inCollectionState = bit(Self.bitInCollectionState)
    hasDebugInfo = bit(Self.bitHasDebugInfo)
    unknownFlagBit3 = bit(Self.bitUnknown)
  }
}
