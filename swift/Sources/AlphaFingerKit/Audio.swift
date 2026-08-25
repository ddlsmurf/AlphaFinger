import Foundation

/// PCM recovered from a collection's audio records.
public struct AudioTimeline: Sendable {
  public let samples: [Int16]
  public let sampleRateHz: UInt32

  public init(samples: [Int16], sampleRateHz: UInt32) {
    self.samples = samples
    self.sampleRateHz = sampleRateHz
  }
}

public enum AudioDecoder {
  /// The ring's audio is 16-bit mono.
  public static let bytesPerSample = 2
  public static let channelCount = 1

  /// Decodes an `UNCOMPRESSED_16BIT_AUDIO` payload: raw little-endian Int16 PCM.
  public static func decodeUncompressed(_ payload: [UInt8]) throws -> [Int16] {
    guard payload.count % bytesPerSample == 0 else {
      throw AlphaFingerDecodeError.lengthMismatch(
        field: "uncompressed audio payload (must be a whole number of 16-bit samples)",
        declared: payload.count,
        actual: payload.count - payload.count % bytesPerSample)
    }
    var samples = [Int16](repeating: 0, count: payload.count / bytesPerSample)
    for index in samples.indices {
      let base = index * bytesPerSample
      samples[index] = Int16(bitPattern:
        UInt16(payload[base]) | UInt16(payload[base + 1]) << 8)
    }
    return samples
  }

  /// Decodes `COMPRESSED_16BIT_AUDIO`: DPCM with Golomb-Rice coded residuals.
  /// See `RiceDecoder` for the format and where it was reversed from.
  ///
  /// Returns the timeline rather than bare samples because the sample rate is
  /// carried in the record itself, not alongside it.
  public static func decodeRice(_ payload: [UInt8]) throws -> AudioTimeline {
    try RiceDecoder.decode(payload: payload)
  }
}

/// Removes the DC offset.
public enum DCBias {
  public static func removed(from samples: [Int16]) -> [Int16] {
    guard !samples.isEmpty else { return samples }
    let mean = samples.reduce(0) { $0 + Int64($1) } / Int64(samples.count)
    return samples.map { sample in
      Int16(clamping: Int64(sample) - mean)
    }
  }
}

/// Minimal RIFF/WAVE writer, so a capture can be listened to.
public enum WAVWriter {
  public static func data(samples: [Int16], sampleRateHz: UInt32) -> Data {
    let bitsPerSample: UInt16 = 16
    let channels = UInt16(AudioDecoder.channelCount)
    let byteRate = sampleRateHz * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * bitsPerSample / 8
    let dataBytes = UInt32(samples.count * MemoryLayout<Int16>.size)

    var out = Data()
    func ascii(_ text: String) { out.append(contentsOf: Array(text.utf8)) }
    func u32(_ value: UInt32) {
      out.append(contentsOf: [UInt8(truncatingIfNeeded: value),
                              UInt8(truncatingIfNeeded: value >> 8),
                              UInt8(truncatingIfNeeded: value >> 16),
                              UInt8(truncatingIfNeeded: value >> 24)])
    }
    func u16(_ value: UInt16) {
      out.append(contentsOf: [UInt8(truncatingIfNeeded: value),
                              UInt8(truncatingIfNeeded: value >> 8)])
    }

    ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(channels)
    u32(sampleRateHz); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
    ascii("data"); u32(dataBytes)
    for sample in samples {
      u16(UInt16(bitPattern: sample))
    }
    return out
  }
}
