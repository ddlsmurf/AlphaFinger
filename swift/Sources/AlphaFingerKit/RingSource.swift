import Foundation

/// One collection as it came off the ring, plus everything decoded from it.
///
/// `bytes` is kept so a future decoder fix can be re-run over an archived
/// recording without the ring.
public struct RingCollection: Sendable {
  public let index: UInt32
  public let bytes: [UInt8]
  public let records: [CollectionRecord]

  public init(index: UInt32, bytes: [UInt8]) throws {
    self.index = index
    self.bytes = bytes
    self.records = try CollectionParser.parse(bytes)
  }

  private func firstPayload(_ type: RecordType) -> [UInt8]? {
    records.first { $0.type == type }?.payload
  }

  /// Which multipart run this belongs to. Collections carrying no multipart
  /// record stand alone, so they are their own run.
  public var multipartStartIndex: UInt32 {
    multipartInfo?.startIndex ?? index
  }

  public var multipartInfo: MultiPartInfo? {
    guard let record = records.first(where: { $0.type == .collectionMultiPartInfo })
    else { return nil }
    return try? MultiPartInfo(record: record)
  }

  public var buttonPress: ButtonPressSequence? {
    guard let record = records.first(where: { $0.type == .buttonPressSequence })
    else { return nil }
    return try? ButtonPressSequence(record: record)
  }

  /// The ring's own clock, as a Unix timestamp.
  ///
  /// `unixTime = SWING_UTC.seconds + (int32)SWING_TIME_CORRECTION.diff + 1`.
  /// The `0xFFFFFFFF` correction sentinel is `-1` when read signed, which cancels
  /// the `+1` — so collections carrying a real correction and those carrying only
  /// a raw UTC both fall out of the same expression, with no special case.
  public var ringTimestamp: Date? {
    guard let utc = firstPayload(.swingUtc), utc.count >= 4 else { return nil }
    let seconds = Int64(UInt32(utc[0]) | UInt32(utc[1]) << 8
                        | UInt32(utc[2]) << 16 | UInt32(utc[3]) << 24)
    var correction: Int64 = 0
    if let raw = firstPayload(.swingTimeCorrection), raw.count >= 4 {
      let unsigned = UInt32(raw[0]) | UInt32(raw[1]) << 8
        | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
      correction = Int64(Int32(bitPattern: unsigned))
    }
    let unix = seconds + correction + 1
    // Anything before 2011-08-10 is implausible and rejected,
    // rather than filing a recording as 1970.
    guard unix > Self.earliestPlausibleUnixTime else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(unix))
  }

  static let earliestPlausibleUnixTime: Int64 = 0x4E41_FCA7

  /// Battery, in millivolts. 1560-1579 mV across the captured collections.
  ///
  /// `firstPayload` returns the record's payload with no header, so the value
  /// starts at offset 0. The previous version required 4 bytes and read from
  /// offset 2 -- the payload is 2 bytes, so it silently returned nil every time
  /// and no sidecar ever carried a battery reading.
  public var batteryMilliVolts: UInt16? {
    guard let raw = firstPayload(.batteryVoltage), raw.count >= 2 else { return nil }
    return UInt16(raw[0]) | UInt16(raw[1]) << 8
  }

  /// The ring's own hardware identifier, lower-case hex.
  ///
  /// Present in every collection and constant for a given ring, so it is what
  /// distinguishes recordings made by different rings.
  public var deviceIdentifier: String? {
    guard let raw = firstPayload(.deviceId), !raw.isEmpty else { return nil }
    return raw.map { String(format: "%02x", $0) }.joined()
  }

  public var lifetimeCollectionCount: UInt32? {
    guard let raw = firstPayload(.lifetimeCollectionCount), raw.count >= 4 else { return nil }
    return UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
  }

  /// `hardware major.minor / firmware major.minor`. The payload is 4 bytes.
  public var platformVersions: String? {
    guard let raw = firstPayload(.platformVersions), raw.count >= 4 else { return nil }
    return "hw \(raw[0]).\(raw[1]) fw \(raw[2]).\(raw[3])"
  }

  public var compressedAudio: [CollectionRecord] {
    records.filter { $0.type == .compressed16BitAudio }
  }
}

/// Anything that can produce collections: a live ring, or a recorded session.
///
/// Splitting this out is what lets the whole application — grouping, debouncing,
/// classification, naming, filing — be exercised against a real captured session
/// with no hardware, leaving only the transport to debug against a ring.
public protocol RingSource: AnyObject {
  /// Called for each collection, in ascending index order.
  var onCollection: ((RingCollection) -> Void)? { get set }
  /// Called when the source cannot continue. Not fatal by itself; a live source
  /// may recover on the next poll.
  var onError: ((Error) -> Void)? { get set }

  func start()
  func stop()
}

/// Replays collections from `.bin` blobs on disk, as written by
/// `tools/capturedump.py --blobs`.
///
/// Emits synchronously on `start()` rather than re-creating the original timing:
/// tests want determinism, and the debouncer is driven by the ring's own
/// timestamps rather than by arrival time.
public final class ReplayRingSource: RingSource {
  public var onCollection: ((RingCollection) -> Void)?
  public var onError: ((Error) -> Void)?

  private let blobDirectory: URL
  private let startingAfterIndex: UInt32?

  /// `startingAfterIndex` skips blobs already dealt with, mirroring what the
  /// index cursor does for a live ring.
  public init(blobDirectory: URL, startingAfterIndex: UInt32? = nil) {
    self.blobDirectory = blobDirectory
    self.startingAfterIndex = startingAfterIndex
  }

  public func start() {
    let files: [URL]
    do {
      files = try FileManager.default
        .contentsOfDirectory(at: blobDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "bin" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      onError?(error)
      return
    }

    for file in files {
      guard let index = Self.index(from: file.lastPathComponent) else {
        onError?(AlphaFingerDecodeError.unsupported(
          "cannot read a collection index from '\(file.lastPathComponent)'; "
          + "expected a name like collection-000.bin"))
        continue
      }
      if let after = startingAfterIndex, index <= after { continue }
      guard let data = FileManager.default.contents(atPath: file.path) else {
        onError?(AlphaFingerDecodeError.unsupported("cannot read \(file.path)"))
        continue
      }
      do {
        onCollection?(try RingCollection(index: index, bytes: [UInt8](data)))
      } catch {
        onError?(error)
      }
    }
  }

  public func stop() {}

  static func index(from fileName: String) -> UInt32? {
    let digits = fileName.drop { !$0.isNumber }.prefix { $0.isNumber }
    return digits.isEmpty ? nil : UInt32(digits)
  }
}
