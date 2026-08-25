import Foundation

/// Errors raised while decoding data that came off the ring.
///
/// Every case carries the values that made the decode fail, so a failure in the
/// field can be diagnosed from the message alone.
public enum AlphaFingerDecodeError: Error, CustomStringConvertible {
  case truncated(field: String, offset: Int, needed: Int, available: Int)
  case unexpectedLength(field: String, length: Int, expected: [Int])
  case lengthMismatch(field: String, declared: Int, actual: Int)
  case unknownRecordType(code: UInt8, offset: Int)
  case unsupported(String)

  public var description: String {
    switch self {
    case let .truncated(field, offset, needed, available):
      return "truncated reading \(field): need \(counted(needed, "byte")) at offset \(offset), "
        + "only \(available) available"
    case let .unexpectedLength(field, length, expected):
      return "unexpected length for \(field): got \(length), expected one of \(expected)"
    case let .lengthMismatch(field, declared, actual):
      return "length mismatch in \(field): header declares \(declared), buffer holds \(actual)"
    case let .unknownRecordType(code, offset):
      return "unknown record type 0x\(String(code, radix: 16)) at offset \(offset); "
        + "the ring's format is not forward-compatible, so parsing cannot continue"
    case let .unsupported(what):
      return "unsupported: \(what)"
    }
  }
}

/// Bounds-checked little-endian reader over a byte buffer.
///
/// The ring's records are packed, so multi-byte fields land on unaligned offsets
/// (a button-press sequence's own field is at +2). Every read here is
/// byte-by-byte for that reason -- never bind a struct over this data.
public struct ByteReader {
  public let bytes: [UInt8]
  public private(set) var offset: Int

  public init(_ bytes: [UInt8], offset: Int = 0) {
    self.bytes = bytes
    self.offset = offset
  }

  public var remaining: Int { bytes.count - offset }

  public mutating func seek(to newOffset: Int) { offset = newOffset }

  private func check(_ field: String, _ at: Int, _ count: Int) throws {
    guard at >= 0, at + count <= bytes.count else {
      throw AlphaFingerDecodeError.truncated(
        field: field, offset: at, needed: count, available: max(0, bytes.count - at))
    }
  }

  public func u8(at: Int, _ field: String = "u8") throws -> UInt8 {
    try check(field, at, 1)
    return bytes[at]
  }

  public func u16(at: Int, _ field: String = "u16") throws -> UInt16 {
    try check(field, at, 2)
    return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
  }

  public func u24BigEndian(at: Int, _ field: String = "u24be") throws -> UInt32 {
    try check(field, at, 3)
    return UInt32(bytes[at]) << 16 | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2])
  }

  public func u24LittleEndian(at: Int, _ field: String = "u24le") throws -> UInt32 {
    try check(field, at, 3)
    return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16
  }

  public func u32(at: Int, _ field: String = "u32") throws -> UInt32 {
    try check(field, at, 4)
    return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
      | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
  }

  public func slice(at: Int, count: Int, _ field: String = "slice") throws -> [UInt8] {
    try check(field, at, count)
    return Array(bytes[at ..< at + count])
  }
}

/// Little-endian writer, for building Telesto frames.
public struct ByteWriter {
  public private(set) var bytes: [UInt8] = []

  public init() {}

  public mutating func u8(_ value: UInt8) { bytes.append(value) }

  public mutating func u32(_ value: UInt32) {
    bytes.append(UInt8(truncatingIfNeeded: value))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    bytes.append(UInt8(truncatingIfNeeded: value >> 24))
  }

  public mutating func append(_ more: [UInt8]) { bytes.append(contentsOf: more) }
}
