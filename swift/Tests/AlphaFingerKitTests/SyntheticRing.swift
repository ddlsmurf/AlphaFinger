import Foundation
@testable import AlphaFingerKit

/// Builds collections the way the ring does, so the pipeline can be tested
/// end-to-end without a device and without shipping anyone's real recordings.
///
/// This is the inverse of the decoders in `AlphaFingerKit`, and that is the point:
/// `testRiceRoundTrip` encodes a known waveform and decodes it back, which checks
/// the decoder against something regenerable rather than against a fixed blob
/// nobody can reproduce.
enum SyntheticRing {
  static let sampleRateHz: UInt32 = 9997
  static let shift = 4
  static let maxUnary = 8
  static var width: Int { 16 - shift }

  // MARK: - Bit writing

  /// MSB-first, matching `BitReader`.
  struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private(set) var bitCount = 0

    mutating func write(_ bit: Int) {
      if bitCount % 8 == 0 { bytes.append(0) }
      if bit != 0 { bytes[bitCount >> 3] |= 1 << (7 - UInt8(bitCount & 7)) }
      bitCount += 1
    }

    mutating func write(_ value: Int, bits: Int) {
      for index in stride(from: bits - 1, through: 0, by: -1) {
        write((value >> index) & 1)
      }
    }
  }

  // MARK: - Rice encoding

  /// Encodes quantised sample values into a `compressed16BitAudio` payload.
  ///
  /// Second-order DPCM: the residual is the second difference, taken modulo the
  /// sample width so it matches the decoder's wrapping arithmetic exactly.
  static func encodeAudio(values: [Int32]) -> [UInt8] {
    let modulus = 1 << width
    var writer = BitWriter()
    var velocity = 0
    var position = 0

    for value in values {
      let target = Int(value) % modulus
      let wantedVelocity = (target - position + modulus) % modulus
      let residual = (wantedVelocity - velocity + modulus) % modulus
      encode(residual: residual, modulus: modulus, into: &writer)
      velocity = wantedVelocity
      position = target
    }

    var payload: [UInt8] = [UInt8((maxUnary << 4) | shift)]
    payload += withUnsafeBytes(of: UInt32(writer.bitCount).littleEndian) { [UInt8]($0) }
    payload += withUnsafeBytes(of: sampleRateHz.littleEndian) { [UInt8]($0) }
    payload += writer.bytes
    return payload
  }

  /// Zero is a single `1`. Otherwise `m` zeros, a `1`, and a sign bit — where a
  /// residual above half the modulus is encoded as its negative counterpart.
  /// Anything too large for the unary run escapes to a literal.
  private static func encode(residual: Int, modulus: Int, into writer: inout BitWriter) {
    if residual == 0 { return writer.write(1) }

    let negativeMagnitude = modulus - residual
    let magnitude: Int?
    let isNegative: Bool
    if residual <= maxUnary - 1 {
      magnitude = residual
      isNegative = false
    } else if negativeMagnitude <= maxUnary - 1 {
      magnitude = negativeMagnitude
      isNegative = true
    } else {
      magnitude = nil
      isNegative = false
    }

    guard let magnitude else {
      // Escape: a full run of maxUnary zeros, then the residual verbatim.
      for _ in 0 ..< maxUnary { writer.write(0) }
      writer.write(residual, bits: width)
      return
    }
    for _ in 0 ..< magnitude { writer.write(0) }
    writer.write(1)
    writer.write(isNegative ? 1 : 0)
  }

  /// A quiet tone around the mid-scale DC level a real ADC sits at, so the
  /// centring step in `RiceDecoder.pcm` has something to do.
  static func tone(samples: Int, seed: Double = 0) -> [Int32] {
    let centre = Double(1 << (width - 1))
    return (0 ..< samples).map { index in
      let phase = (Double(index) / 32) + seed
      return Int32(centre + 180 * sin(phase))
    }
  }

  // MARK: - Records and collections

  static func record(_ type: RecordType, _ payload: [UInt8]) -> [UInt8] {
    if type.usesWideLength {
      let n = UInt32(payload.count)
      return [type.rawValue] + withUnsafeBytes(of: n.littleEndian) { [UInt8]($0) } + payload
    }
    let n = UInt16(payload.count)
    return [type.rawValue] + withUnsafeBytes(of: n.littleEndian) { [UInt8]($0) } + payload
  }

  /// Wraps records in the container header. Uses the little-endian total-length
  /// form, which is the one selected when byte 3 is zero.
  static func collection(records: [[UInt8]]) -> [UInt8] {
    let body = records.flatMap { $0 }
    let total = body.count + 4
    return [UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF),
            UInt8((total >> 16) & 0xFF), 0x00] + body
  }

  /// Everything a real collection carries, with synthetic identifiers.
  static func part(startIndex: UInt32, isMultiPart: Bool, isFinalPart: Bool,
                   pressSequence: UInt32, pressCount: UInt32,
                   unixTime: UInt32, samples: Int, seed: Double = 0) -> [UInt8] {
    func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { [UInt8]($0) } }
    var records: [[UInt8]] = []
    records.append(record(.swingUtc, u32(unixTime)))
    records.append(record(.collectionMultiPartInfo,
                          u32(startIndex) + [isMultiPart ? 1 : 0, isFinalPart ? 1 : 0]))
    records.append(record(.buttonPressSequence, u32(pressSequence) + u32(pressCount)))
    if samples > 0 {
      records.append(record(.compressed16BitAudio,
                            encodeAudio(values: tone(samples: samples, seed: seed))))
    }
    records.append(record(.batteryVoltage, [0x2b, 0x06]))          // 1579 mV
    records.append(record(.deviceId, [0, 0, 0, 0, 0, 1]))          // not a real ring
    records.append(record(.platformVersions, [0x0b, 0x00, 0x03, 0x4b]))
    return collection(records: records)
  }
}
