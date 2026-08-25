import Foundation

/// The ring's memory-oriented transport. Requests are reads and writes against
/// virtual addresses.
public enum TelestoOperation: UInt8, Sendable {
  case noOperation = 0
  case eraseMemory = 1
  case programMemory = 2
  case readMemory = 3
  case cancelOperation = 4

  /// Whether the ring streams bytes on the data channel in reply.
  ///
  /// Only reads do. The response's `byteCount` field is populated either way --
  /// for a write it reports the bytes *accepted*, not a payload to collect -- so a
  /// client that keys off `byteCount > 0` will wait forever for data a write never
  /// sends. Measured over a live session: 32 reads produced
  /// 1-24 data notifications each, the one program and the one erase produced
  /// none.
  public var expectsDataPayload: Bool {
    self == .readMemory
  }
}

/// Virtual addresses exposed by the ring.
public enum TelestoAddress {
  public static let applicationDataStore: UInt32 = 0x4000_0000
  public static let collectionBase: UInt32 = 0x4002_0000
  public static let storedCollectionIndexes: UInt32 = 0x4003_0005
  /// Written with the current Unix time (u32 LE) to set the ring's clock.
  public static let ringClock: UInt32 = 0x4003_0001
  public static let platformVersions: UInt32 = 0x4003_0006
}

/// A control-channel request.
///
/// Encodes to exactly 13 packed little-endian bytes; note `address` starts at
/// byte 1, so the 32-bit fields are unaligned.
public struct TelestoRequest: Equatable, Sendable {
  public static let encodedLength = 13

  public let operation: TelestoOperation
  public let address: UInt32
  public let offset: UInt32
  public let length: UInt32

  public init(operation: TelestoOperation, address: UInt32,
              offset: UInt32 = 0, length: UInt32 = 0) {
    self.operation = operation
    self.address = address
    self.offset = offset
    self.length = length
  }

  public func encoded() -> [UInt8] {
    var writer = ByteWriter()
    writer.u8(operation.rawValue)
    writer.u32(address)
    writer.u32(offset)
    writer.u32(length)
    precondition(writer.bytes.count == Self.encodedLength,
                 "Telesto request must encode to \(Self.encodedLength) bytes, "
                 + "got \(writer.bytes.count)")
    return writer.bytes
  }

  /// Reads one collection by index.
  ///
  /// `length` 0 is the normal case: it asks the ring how large the collection is
  /// *and* makes it stream that many bytes.
  public static func readCollection(index: UInt32, length: UInt32 = 0) -> TelestoRequest {
    TelestoRequest(operation: .readMemory,
                   address: TelestoAddress.collectionBase &+ index,
                   offset: 0, length: length)
  }

  /// Reads the window of collection indices the ring currently holds.
  public static let readStoredCollectionIndexes = TelestoRequest(
    operation: .readMemory, address: TelestoAddress.storedCollectionIndexes,
    offset: 0, length: 4)

  /// Sets the ring's clock.
  ///
  /// The current Unix time is written before each fetch batch. It
  /// matters: collection timestamps come from the ring's own clock, and they are
  /// what recordings get named after, so an unsynchronised ring produces
  /// wrongly-dated files.
  public static func syncClock(to date: Date = Date()) -> (TelestoRequest, [UInt8]) {
    var writer = ByteWriter()
    writer.u32(UInt32(truncatingIfNeeded: Int(date.timeIntervalSince1970)))
    let request = TelestoRequest(operation: .programMemory,
                                 address: TelestoAddress.ringClock,
                                 offset: 0, length: UInt32(writer.bytes.count))
    return (request, writer.bytes)
  }
}

/// Payload framing on the data channel: a u32 total length that counts itself.
/// From `TelestoLengthPrefixedData_create`.
public enum TelestoLengthPrefixedData {
  public static let prefixLength = 4

  public static func encode(_ payload: [UInt8]) -> [UInt8] {
    var writer = ByteWriter()
    writer.u32(UInt32(payload.count + prefixLength))
    writer.append(payload)
    return writer.bytes
  }

  public static func decode(_ frame: [UInt8]) throws -> [UInt8] {
    let reader = ByteReader(frame)
    let declared = Int(try reader.u32(at: 0, "telesto data length prefix"))
    guard declared == frame.count else {
      throw AlphaFingerDecodeError.lengthMismatch(
        field: "telesto data frame", declared: declared, actual: frame.count)
    }
    return try reader.slice(at: prefixLength, count: frame.count - prefixLength, "payload")
  }
}

/// The window of collection indices the ring currently holds.
public struct TelestoStoredCollectionIndexes: Equatable, Sendable {
  public let rangeStart: UInt32
  public let rangeEnd: UInt32
}

/// Inbound control frames are accumulated to exactly this many bytes before the
/// controller processes one.
///
/// **Unverified**: the 12-byte response layout has not been reversed. Capture
/// real notifications before implementing a decoder here.
public enum TelestoControlResponse {
  public static let frameLength = 12
}

/// The ring's reply on the control channel. Layout confirmed against 51 matched
/// request/response pairs observed on the wire.
///
/// A `READ_MEMORY` with `length == 0` is both a size query and a transfer
/// request: `byteCount` reports how much is available, and the ring then streams
/// exactly that many bytes on the data channel.
public struct TelestoResponse: Equatable, Sendable {
  public static let encodedLength = TelestoControlResponse.frameLength

  /// 0 on success. Non-zero was never observed, so its meaning is unknown.
  public let status: UInt32
  /// Zero in every observed exchange.
  public let reserved: UInt32
  /// Bytes the ring is about to send on the data channel.
  public let byteCount: UInt32

  public var succeeded: Bool { status == 0 }

  public init?(bytes: [UInt8]) {
    guard bytes.count == Self.encodedLength else { return nil }
    let reader = ByteReader(bytes)
    guard let status = try? reader.u32(at: 0, "telesto status"),
          let reserved = try? reader.u32(at: 4, "telesto reserved"),
          let byteCount = try? reader.u32(at: 8, "telesto byteCount") else { return nil }
    self.status = status
    self.reserved = reserved
    self.byteCount = byteCount
  }
}
