import Foundation

/// Record type codes inside a collection.
///
/// The values are
/// **banded, not dense** -- switch on them, never index by them.
public enum RecordType: UInt8, CaseIterable, Sendable {
  case deviceId = 1
  case swingUtc = 2
  case impactTime = 3
  case accelCalibration = 4
  case gyroCalibration = 5
  case imuData = 6
  case magCalibration = 7
  case magData = 8
  case sensorTemperature = 9
  case targetLineAim = 10
  case swingSetup = 11
  case clubSettings = 12
  case vsrData = 13
  case multiAccelData = 14
  case accel2Calibration = 15
  case gyro2Calibration = 16
  case haccel1Calibration = 17
  case haccel2Calibration = 18
  case stFifoCompressed = 33
  case stSensorConfig = 34
  case fullClubSettings = 35
  case allSensorCalibrations = 36
  case platformVersions = 37
  case userData = 38
  case applicationDataStore = 39
  case stFifoFirmwareCompressed = 40
  case detectorData = 41
  case lastStationaryData = 48
  case stationaryDataVersion = 49
  case croppedStationaryData = 50
  case stationaryDataSensorConfigs = 51
  case collectionSensorConfigs = 52
  case swingTimeCorrection = 53
  case batteryVoltage = 55
  case uncompressed16BitAudio = 80
  case compressed16BitAudio = 81
  case collectionMultiPartInfo = 82
  case buttonPressSequence = 83
  case lifetimeCollectionCount = 84
  case recordsDataTransfer = 255

  /// Audio records carry a u32 length; every other record uses u16. Getting this
  /// wrong desynchronises the entire walk.
  public var usesWideLength: Bool {
    self == .uncompressed16BitAudio || self == .compressed16BitAudio
  }
}

/// One record, as a view onto the collection buffer.
///
/// `payload` excludes the type byte and the length field. `bodyOffset` is where
/// the length field sits -- the record layouts are relative to that
/// position, which is why their layouts all begin with `size` at +0.
public struct CollectionRecord: Sendable {
  public let type: RecordType
  public let bodyOffset: Int
  public let payload: [UInt8]
}

/// Parses the record container produced by the ring.
///
/// Walks the records packed inside a collection.
public enum CollectionParser {
  static let headerLength = 3
  static let extendedLengthMarker: UInt8 = 0xFF
  /// Type 35 terminates the walk early.
  static let terminatingType = RecordType.fullClubSettings

  /// Returns the offset at which records begin, validating the length header.
  ///
  /// Three header forms exist, chosen by a heuristic on byte 3;
  /// this reproduces that choice exactly.
  static func recordsStart(in bytes: [UInt8]) throws -> Int {
    guard bytes.count >= headerLength else {
      throw AlphaFingerDecodeError.truncated(
        field: "collection header", offset: 0, needed: headerLength, available: bytes.count)
    }
    let reader = ByteReader(bytes)
    let byte3IsZero = bytes.count > headerLength && bytes[3] == 0

    if bytes.count == headerLength || !byte3IsZero {
      let declared: Int
      if bytes[0] == extendedLengthMarker {
        declared = Int(try reader.u16(at: 1, "collection payload length"))
      } else {
        declared = Int(try reader.u24BigEndian(at: 0, "collection payload length"))
      }
      guard declared == bytes.count - headerLength else {
        throw AlphaFingerDecodeError.lengthMismatch(
          field: "collection payload", declared: declared, actual: bytes.count - headerLength)
      }
      return headerLength
    }

    let declaredTotal = Int(try reader.u24LittleEndian(at: 0, "collection total length"))
    guard declaredTotal == bytes.count else {
      throw AlphaFingerDecodeError.lengthMismatch(
        field: "collection total", declared: declaredTotal, actual: bytes.count)
    }
    return headerLength + 1
  }

  /// Whether `bytes` is a complete, self-consistent collection container.
  ///
  /// Three things must agree: the declared length matches the buffer, every
  /// record type is known, and the records walk to exactly the end. Random audio
  /// passing all three is vanishingly unlikely, which is what makes this usable
  /// both to reject a corrupted transfer and to resynchronise a capture that has
  /// lost alignment.
  public static func isWellFormed(_ bytes: [UInt8]) -> Bool {
    guard let records = try? parse(bytes), !records.isEmpty else { return false }
    // `parse` already validates the header and every type code; the remaining
    // question is whether the walk landed exactly on the end.
    guard let last = records.last else { return false }
    let headerBytes = last.type.usesWideLength ? 5 : 3
    return last.bodyOffset - 1 + headerBytes + last.payload.count == bytes.count
  }

  /// Walks every record. Throws on an unknown type code, as the device's own
  /// parser aborts -- the format is not forward-compatible, and silently
  /// skipping would resynchronise onto garbage.
  public static func parse(_ bytes: [UInt8]) throws -> [CollectionRecord] {
    var cursor = try recordsStart(in: bytes)
    let reader = ByteReader(bytes)
    var records: [CollectionRecord] = []

    while cursor < bytes.count {
      let rawType = try reader.u8(at: cursor, "record type")
      guard let type = RecordType(rawValue: rawType) else {
        throw AlphaFingerDecodeError.unknownRecordType(code: rawType, offset: cursor)
      }
      if type == terminatingType { break }

      let bodyOffset = cursor + 1
      let payloadLength: Int
      let headerBytes: Int
      if type.usesWideLength {
        payloadLength = Int(try reader.u32(at: bodyOffset, "audio record length"))
        headerBytes = 5
      } else {
        payloadLength = Int(try reader.u16(at: bodyOffset, "record length"))
        headerBytes = 3
      }

      let payload = try reader.slice(
        at: cursor + headerBytes, count: payloadLength, "record payload")
      records.append(CollectionRecord(type: type, bodyOffset: bodyOffset, payload: payload))
      cursor += headerBytes + payloadLength
    }
    return records
  }
}

/// Typed views over the records that matter for the ring.
///
/// Offsets are relative to the length field, matching the on-wire
/// definitions. All fields are packed and therefore unaligned.
/// The button presses that produced a collection.
///
/// `count` is how many presses are in the burst, and `sequence` is a **bitmask**:
/// bit *i* set means press *i* was **long** (i.e. a recording) rather than short
/// (a tap). Confirmed against all 21 collections of a real captured session --
/// `{sequence: 2, count: 2}` decodes to `short + long`, which is exactly the
/// "tap, then record" the wearer performed.
///
/// This supersedes guessing from audio duration: the ring states the gesture, so
/// an N-tap gesture is simply N short presses.
public struct ButtonPressSequence: Equatable, Sendable {
  public enum Press: Equatable, Sendable {
    case short
    case long
  }

  /// Presses beyond this are treated as a malformed record rather than trusted.
  /// The mask is 32 bits, so a count above that cannot be represented anyway.
  public static let maximumPresses: UInt32 = 32

  public let sequence: UInt32
  public let count: UInt32

  public init(record: CollectionRecord) throws {
    let reader = ByteReader(record.payload)
    sequence = try reader.u32(at: 0, "buttonPressSequence.sequence")
    count = try reader.u32(at: 4, "buttonPressSequence.count")
  }

  public init(sequence: UInt32, count: UInt32) {
    self.sequence = sequence
    self.count = count
  }

  /// Nil when `count` exceeds what the bitmask can describe, so callers fall back
  /// rather than silently reading a truncated pattern.
  public var presses: [Press]? {
    guard count <= Self.maximumPresses else { return nil }
    return (0 ..< Int(count)).map { (sequence >> $0) & 1 == 1 ? .long : .short }
  }

  /// A long press is the ring recording; taps are short.
  public var containsRecording: Bool {
    presses?.contains(.long) ?? false
  }

  /// How many short presses -- the "N" in an N-tap gesture.
  public var tapCount: UInt32 {
    UInt32(presses?.filter { $0 == .short }.count ?? 0)
  }

  /// `short+long`, for logs and the metadata sidecar.
  public var patternDescription: String {
    guard let presses, !presses.isEmpty else { return "none" }
    return presses.map { $0 == .long ? "long" : "short" }.joined(separator: "+")
  }
}

public struct MultiPartInfo: Equatable, Sendable {
  public let startIndex: UInt32
  public let isMultiPart: Bool
  public let isFinalPart: Bool

  public init(record: CollectionRecord) throws {
    let reader = ByteReader(record.payload)
    startIndex = try reader.u32(at: 0, "multiPartInfo.startIndex")
    isMultiPart = try reader.u8(at: 4, "multiPartInfo.isMultiPart") != 0
    isFinalPart = try reader.u8(at: 5, "multiPartInfo.isFinalPart") != 0
  }
}
