import Foundation

/// Decoder for `COMPRESSED_16BIT_AUDIO` (record type 0x51).
///
/// The scheme is **second-order** DPCM with Golomb-Rice coded residuals:
///
/// - Samples are quantised: `shift` low bits are dropped, so an effective sample
///   is `16 - shift` bits wide and is shifted back left on output.
/// - Each residual is a *modular* value in that width, and feeds a **double
///   integrator**:
///
///   ```
///   velocity += residual
///   position += velocity        // position is the sample
///   ```
///
///   Getting this wrong is audible rather than subtle: single integration still
///   produces speech-shaped output, but leaves a ~17,000-sample discontinuity at
///   every record boundary -- a loud click every ~0.2 s.
/// - Residuals are unary-coded with an escape: a leading `1` means zero; `0`
///   followed by `n-1` more zeros and a `1` means magnitude `n`, followed by one
///   sign bit; and a run of `maxUnary` zeros escapes to a literal of `16 - shift`
///   raw bits.
///
/// Bits are read **MSB-first** within each byte.
public struct RiceAudioRecord {
  /// Layout, relative to the start of the record payload (i.e. just past the
  /// `[u8 type][u32 size]` header). Offsets 1 and 5 are unaligned.
  static let configOffset = 0
  static let bitCountOffset = 1
  static let sampleRateOffset = 5
  static let bitstreamOffset = 9

  /// Low nibble of the config byte: how many low bits were dropped per sample.
  public let shift: Int
  /// High nibble: the unary run length that escapes to a literal.
  public let maxUnary: Int
  public let bitCount: Int
  public let sampleRateHz: UInt32
  public let bitstream: [UInt8]

  /// Effective sample width in bits, after quantisation.
  public var width: Int { 16 - shift }

  public init(payload: [UInt8]) throws {
    let reader = ByteReader(payload)
    let config = try reader.u8(at: Self.configOffset, "rice config")
    shift = Int(config & 0x0F)
    maxUnary = Int(config >> 4)
    bitCount = Int(try reader.u32(at: Self.bitCountOffset, "rice bitCount"))
    sampleRateHz = try reader.u32(at: Self.sampleRateOffset, "rice sampleRateHz")

    guard shift < 16 else {
      throw AlphaFingerDecodeError.unsupported(
        "rice shift \(shift) leaves no sample width (config 0x\(String(config, radix: 16)))")
    }
    guard maxUnary >= 1 else {
      throw AlphaFingerDecodeError.unsupported(
        "rice maxUnary is 0 (config 0x\(String(config, radix: 16))); no residual could terminate")
    }
    // The device guarantees exactly this relationship; a payload that violates it
    // would desynchronise the bit reader rather than fail cleanly.
    let availableBits = (payload.count - Self.bitstreamOffset) * 8
    guard availableBits >= bitCount else {
      throw AlphaFingerDecodeError.lengthMismatch(
        field: "rice bitstream (header declares more bits than the payload holds)",
        declared: bitCount, actual: availableBits)
    }
    bitstream = try reader.slice(at: Self.bitstreamOffset,
                                 count: payload.count - Self.bitstreamOffset, "rice bitstream")
  }
}

/// MSB-first bit reader bounded by an explicit bit count.
struct BitReader {
  private let bytes: [UInt8]
  private let limit: Int
  private var position = 0

  init(_ bytes: [UInt8], bitCount: Int) {
    self.bytes = bytes
    self.limit = bitCount
  }

  var isExhausted: Bool { position >= limit }

  mutating func bit() -> Int? {
    guard position < limit else { return nil }
    let value = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
    position += 1
    return Int(value)
  }

  mutating func bits(_ count: Int) -> Int? {
    var value = 0
    for _ in 0 ..< count {
      guard let next = bit() else { return nil }
      value = value << 1 | next
    }
    return value
  }
}

/// One decoded audio record, still in the codec's own domain.
///
/// `values` are the raw predictor outputs: unsigned, modulo `2^(16 - shift)`.
/// They are **not** signed samples. The recorded signal sits at whatever DC level
/// the ring's ADC produced (observed around 1100 of 4096), so interpreting the
/// accumulator as a signed two's-complement value flips any sample that crosses
/// half-scale into full-scale negative -- an extremely loud click. Centring has to
/// happen in this domain, before the values are scaled into `Int16`.
public struct QuantisedAudio {
  public let values: [Int32]
  /// Bits dropped per sample; scaling back up is `value << shift`.
  public let shift: Int
  public let sampleRateHz: UInt32
}

public enum RiceDecoder {
  /// Centres one or more decoded records on their common mean and scales them to
  /// PCM.
  ///
  /// Takes all the parts of a recording together: a multipart recording is split
  /// across collections, and centring each part on its own mean would introduce a
  /// step at every boundary.
  public static func pcm(_ parts: [QuantisedAudio]) throws -> AudioTimeline {
    guard let first = parts.first else {
      throw AlphaFingerDecodeError.unsupported("no audio records to convert to PCM")
    }
    let values = parts.flatMap(\.values)
    guard !values.isEmpty else {
      return AudioTimeline(samples: [], sampleRateHz: first.sampleRateHz)
    }
    let mean = values.reduce(Int64(0)) { $0 + Int64($1) } / Int64(values.count)
    let samples = values.map { value in
      Int16(clamping: (Int64(value) - mean) << first.shift)
    }
    return AudioTimeline(samples: samples, sampleRateHz: first.sampleRateHz)
  }

  /// Decodes one payload and converts it on its own. For a multipart recording,
  /// prefer `decodeQuantised` on each part followed by a single `pcm` call.
  public static func decode(payload: [UInt8]) throws -> AudioTimeline {
    try pcm([decodeQuantised(payload: payload)])
  }

  /// Decodes a whole `COMPRESSED_16BIT_AUDIO` payload to raw predictor values.
  ///
  /// Stops cleanly when the bitstream is exhausted — that is the normal
  /// termination condition, not an error; the device's decoder returns status 3
  /// for it and the caller treats that as success.
  public static func decodeQuantised(payload: [UInt8]) throws -> QuantisedAudio {
    let record = try RiceAudioRecord(payload: payload)
    var reader = BitReader(record.bitstream, bitCount: record.bitCount)
    let modulus = 1 << record.width

    var values: [Int32] = []
    values.reserveCapacity(record.bitCount / 4)
    // Accumulation is in 16 bits, but only the low `width` bits survive the
    // final shift-and-truncate, so modular arithmetic at `width` is equivalent.
    var velocity = 0
    var position = 0

    decoding: while true {
      guard let first = reader.bit() else { break }

      let residual: Int
      if first == 1 {
        residual = 0
      } else {
        // Count the zero run. It began with the bit just read.
        var runLength = 1
        var terminator = 0
        while runLength < record.maxUnary {
          runLength += 1
          guard let next = reader.bit() else { break decoding }
          terminator = next
          if next == 1 { break }
        }

        if terminator == 0 {
          // Escaped: the residual follows as a literal.
          guard let literal = reader.bits(record.width) else { break decoding }
          residual = literal
        } else {
          let magnitude = runLength - 1
          guard let isNegative = reader.bit() else { break decoding }
          residual = isNegative == 1 ? (modulus - magnitude) % modulus : magnitude
        }
      }

      velocity = (velocity + residual) % modulus
      position = (position + velocity) % modulus
      values.append(Int32(position))
    }

    return QuantisedAudio(values: values, shift: record.shift,
                          sampleRateHz: record.sampleRateHz)
  }
}
