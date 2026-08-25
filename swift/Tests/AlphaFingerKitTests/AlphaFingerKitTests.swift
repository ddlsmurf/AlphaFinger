import XCTest
@testable import AlphaFingerKit

/// These are vector tests over synthetic bytes built to the spec in
/// the wire format. They prove the implementation matches what was read off the
/// binary; they do NOT prove the spec matches the hardware. Captures from a real
/// ring go in captures/ and are added here once available.
final class AdvertisementTests: XCTestCase {
  /// fingerprint 0xDEADBEEF, count 7, flags: isMoving | inCollectionState
  private let payload: [UInt8] = [0xEF, 0xBE, 0xAD, 0xDE, 0x07, 0b1010_0000]

  func testParsesSixByteForm() throws {
    let advertisement = try RingAdvertisement(manufacturerData: payload)
    XCTAssertEqual(advertisement.stateFingerprint, 0xDEAD_BEEF)
    XCTAssertEqual(advertisement.rawCollectionCount, 7)
    XCTAssertTrue(advertisement.isMoving)
    XCTAssertTrue(advertisement.inCollectionState)
    XCTAssertFalse(advertisement.needsServicing)
    XCTAssertFalse(advertisement.hasDebugInfo)
  }

  /// CoreBluetooth includes the 2-byte company ID, so Apple platforms see 8
  /// bytes where Android sees 6. Both must decode identically.
  func testEightByteFormSkipsCompanyIdentifier() throws {
    let withCompanyId: [UInt8] = [0x11, 0x22] + payload
    let a = try RingAdvertisement(manufacturerData: withCompanyId)
    let b = try RingAdvertisement(manufacturerData: payload)
    XCTAssertEqual(a, b)
  }

  func testRejectsOtherLengths() {
    for length in [0, 5, 7, 9, 12] {
      XCTAssertThrowsError(
        try RingAdvertisement(manufacturerData: [UInt8](repeating: 0, count: length)),
        "length \(length) must be rejected")
    }
  }

  func testFingerprintSentinels() {
    XCTAssertTrue(RingFingerprint.isFailsafe(0xDEAD_DEAD))
    XCTAssertTrue(RingFingerprint.isProductionTest(0xDEAD_BEEF))
    XCTAssertTrue(RingFingerprint.hasNoUser(0x1234_FFFF))
    XCTAssertFalse(RingFingerprint.hasNoUser(0x1234_FFFE))
  }
}

/// `sequence` is a bitmask over `count` presses: bit i set means press i was long
/// (a recording) rather than short (a tap). Verified against every collection in
/// a real captured session.
final class ButtonPressTests: XCTestCase {
  private func press(_ sequence: UInt32, _ count: UInt32) -> ButtonPressSequence {
    ButtonPressSequence(sequence: sequence, count: count)
  }

  func testDecodesTheCapturedGestures() {
    // Collection 6: the plain recording.
    XCTAssertEqual(press(1, 1).patternDescription, "long")
    XCTAssertTrue(press(1, 1).containsRecording)
    XCTAssertEqual(press(1, 1).tapCount, 0)

    // Collection 17: a tap, then a recording -- "tap-then-record".
    XCTAssertEqual(press(2, 2).patternDescription, "short+long")
    XCTAssertTrue(press(2, 2).containsRecording)
    XCTAssertEqual(press(2, 2).tapCount, 1)

    // Collection 20: the double tap.
    XCTAssertEqual(press(0, 2).patternDescription, "short+short")
    XCTAssertFalse(press(0, 2).containsRecording)
    XCTAssertEqual(press(0, 2).tapCount, 2)

    // Collection 18: the single tap.
    XCTAssertEqual(press(0, 1).patternDescription, "short")
    XCTAssertEqual(press(0, 1).tapCount, 1)
  }

  /// No triple tap exists in the capture, so this is built to the confirmed
  /// encoding rather than observed.
  func testTripleTap() {
    let triple = press(0, 3)
    XCTAssertEqual(triple.tapCount, 3)
    XCTAssertFalse(triple.containsRecording)
    XCTAssertEqual(triple.patternDescription, "short+short+short")
  }

  /// A count the 32-bit mask cannot describe is refused, so callers fall back
  /// rather than reading a truncated pattern as though it were complete.
  func testImplausibleCountIsRejected() {
    XCTAssertNil(press(0, 99).presses)
    XCTAssertFalse(press(0, 99).containsRecording)
  }
}

/// When the ring's own account is missing, the classifier must fall back — and
/// must say that it did, so an estimate never passes for a precise answer.
final class ClassifierFallbackTests: XCTestCase {
  private func record(type: RecordType, payload: [UInt8]) -> [UInt8] {
    if type.usesWideLength {
      let n = UInt32(payload.count)
      return [type.rawValue, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
              UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] + payload
    }
    let n = UInt16(payload.count)
    return [type.rawValue, UInt8(n & 0xFF), UInt8(n >> 8)] + payload
  }

  private func collection(index: UInt32, records: [UInt8]) throws -> RingCollection {
    let total = UInt32(records.count + 4)
    let header: [UInt8] = [UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF),
                           UInt8((total >> 16) & 0xFF), UInt8((total >> 24) & 0xFF)]
    return try RingCollection(index: index, bytes: header + records)
  }

  /// A press record present and well-formed: the ring decides, precisely.
  func testUsesThePressRecordWhenPresent() throws {
    let body = record(type: .buttonPressSequence,
                      payload: [0x01, 0, 0, 0, 0x01, 0, 0, 0])   // seq 1, count 1 = long
    let group = CollectionGroup(startIndex: 0,
                                collections: [try collection(index: 0, records: body)])
    guard case let .recording(_, presses, reason) = RecordingClassifier().classify(group)
    else { return XCTFail("a long press must classify as a recording") }
    XCTAssertEqual(reason, .pressRecord)
    XCTAssertEqual(presses?.patternDescription, "long")
  }

  /// No press record at all: fall back to duration, and mark it as a fallback.
  func testFallsBackToDurationAndSaysSo() throws {
    // A multipart marker with no button record; enough to look like a recording.
    let body = record(type: .collectionMultiPartInfo,
                      payload: [0, 0, 0, 0, 0x01, 0x01])
    let group = CollectionGroup(startIndex: 0,
                                collections: [try collection(index: 0, records: body)])
    guard case let .recording(_, _, reason) = RecordingClassifier().classify(group)
    else { return XCTFail("multipart with no press record should still be a recording") }
    XCTAssertEqual(reason, .durationFallback,
                   "the fallback must be reported, not silently treated as precise")
  }

  /// A short, single-part collection with no press record is a tap, not a recording.
  func testShortCollectionWithoutPressRecordIsAGesture() throws {
    let body = record(type: .swingUtc, payload: [0, 0, 0, 0])
    let group = CollectionGroup(startIndex: 5,
                                collections: [try collection(index: 5, records: body)])
    guard case let .gesture(_, _, _, _, reason) = RecordingClassifier().classify(group)
    else { return XCTFail("expected a gesture") }
    XCTAssertEqual(reason, .durationFallback)
  }
}

/// The container validates itself, which is what both the capture tool and the
/// live path use to detect a misaligned stream and recover from it.
final class WellFormednessTests: XCTestCase {
  private func record(type: RecordType, payload: [UInt8]) -> [UInt8] {
    if type.usesWideLength {
      let n = UInt32(payload.count)
      return [type.rawValue, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
              UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] + payload
    }
    let n = UInt16(payload.count)
    return [type.rawValue, UInt8(n & 0xFF), UInt8(n >> 8)] + payload
  }

  private func container(_ records: [UInt8]) -> [UInt8] {
    let total = UInt32(records.count + 4)
    return [UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF),
            UInt8((total >> 16) & 0xFF), UInt8((total >> 24) & 0xFF)] + records
  }

  private var sample: [UInt8] {
    container(record(type: .swingUtc, payload: [1, 2, 3, 4])
              + record(type: .batteryVoltage, payload: [0x10, 0x0E]))
  }

  func testAcceptsAWellFormedContainer() {
    XCTAssertTrue(CollectionParser.isWellFormed(sample))
  }

  /// The exact failure the capture tool hits: bytes from an abandoned transfer
  /// prepended to the next blob. It must not pass.
  func testRejectsAStreamShiftedByLeftoverBytes() {
    let shifted = Array([0xAA, 0xBB, 0xCC] + sample)
    XCTAssertFalse(CollectionParser.isWellFormed(shifted))
  }

  func testRejectsALengthHeaderThatDisagrees() {
    var bad = sample
    bad[0] = bad[0] &+ 1
    XCTAssertFalse(CollectionParser.isWellFormed(bad))
  }

  func testRejectsTruncatedAndEmpty() {
    XCTAssertFalse(CollectionParser.isWellFormed(Array(sample.dropLast(4))))
    XCTAssertFalse(CollectionParser.isWellFormed([]))
  }

  /// Random audio bytes must not be mistaken for a container -- that is what
  /// makes this safe to resynchronise on.
  func testRejectsArbitraryBytes() {
    var generator = SystemRandomNumberGenerator()
    for _ in 0 ..< 200 {
      let noise = (0 ..< 64).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
      XCTAssertFalse(CollectionParser.isWellFormed(noise))
    }
  }
}

final class TelestoTests: XCTestCase {
  func testRequestEncodesToThirteenPackedBytes() {
    let request = TelestoRequest(operation: .readMemory,
                                 address: TelestoAddress.collectionBase,
                                 offset: 0x1122_3344,
                                 length: 0x00AA_BBCC)
    let encoded = request.encoded()
    XCTAssertEqual(encoded.count, TelestoRequest.encodedLength)
    XCTAssertEqual(encoded, [
      0x03,                    // READ_MEMORY
      0x00, 0x00, 0x02, 0x40,  // address 0x40020000, unaligned at +1
      0x44, 0x33, 0x22, 0x11,  // offset
      0xCC, 0xBB, 0xAA, 0x00,  // length
    ])
  }

  func testLengthPrefixCountsItself() throws {
    let payload: [UInt8] = [1, 2, 3, 4, 5]
    let frame = TelestoLengthPrefixedData.encode(payload)
    XCTAssertEqual(frame.count, payload.count + 4)
    XCTAssertEqual(Array(frame.prefix(4)), [9, 0, 0, 0])
    XCTAssertEqual(try TelestoLengthPrefixedData.decode(frame), payload)
  }

  func testRejectsFrameWhoseLengthDisagrees() {
    XCTAssertThrowsError(try TelestoLengthPrefixedData.decode([0xFF, 0, 0, 0, 1, 2]))
  }
}

final class CollectionParserTests: XCTestCase {
  /// Builds a container using the big-endian u24 payload-length header.
  private func container(records: [UInt8]) -> [UInt8] {
    let length = records.count
    // byte 3 must be non-zero for this header form to be selected
    return [UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] + records
  }

  private func record(type: RecordType, payload: [UInt8]) -> [UInt8] {
    if type.usesWideLength {
      let n = UInt32(payload.count)
      return [type.rawValue, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
              UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] + payload
    }
    let n = UInt16(payload.count)
    return [type.rawValue, UInt8(n & 0xFF), UInt8(n >> 8)] + payload
  }

  func testWalksMixedWidthRecords() throws {
    // Audio uses a u32 length while others use u16; a parser that assumes one
    // width desynchronises here.
    let body = record(type: .buttonPressSequence,
                      payload: [0x11, 0x22, 0x33, 0x44, 0x02, 0, 0, 0])
      + record(type: .uncompressed16BitAudio, payload: [0x00, 0x01, 0x00, 0xFF])
      + record(type: .lifetimeCollectionCount, payload: [0x2A, 0, 0, 0])
    let records = try CollectionParser.parse(container(records: body))

    XCTAssertEqual(records.map(\.type),
                   [.buttonPressSequence, .uncompressed16BitAudio, .lifetimeCollectionCount])

    let button = try ButtonPressSequence(record: records[0])
    XCTAssertEqual(button.sequence, 0x4433_2211)
    XCTAssertEqual(button.count, 2)
  }

  func testUnknownRecordTypeAborts() {
    // An unknown record must be an error rather than a skip, or a
    // client resynchronises onto garbage.
    let body: [UInt8] = [0x7E, 0x02, 0x00, 0xAA, 0xBB]
    XCTAssertThrowsError(try CollectionParser.parse(container(records: body))) { error in
      guard case AlphaFingerDecodeError.unknownRecordType = error else {
        return XCTFail("expected unknownRecordType, got \(error)")
      }
    }
  }

  func testRejectsLengthHeaderMismatch() {
    XCTAssertThrowsError(try CollectionParser.parse([0x00, 0x00, 0xFF, 0x01, 0x02]))
  }

  func testMultiPartInfoFieldsArePacked() throws {
    let body = record(type: .collectionMultiPartInfo,
                      payload: [0x0A, 0, 0, 0, 0x01, 0x00])
    let records = try CollectionParser.parse(container(records: body))
    let info = try MultiPartInfo(record: records[0])
    XCTAssertEqual(info.startIndex, 10)
    XCTAssertTrue(info.isMultiPart)
    XCTAssertFalse(info.isFinalPart)
  }
}

final class AudioTests: XCTestCase {
  func testUncompressedIsLittleEndianInt16() throws {
    let samples = try AudioDecoder.decodeUncompressed([0x00, 0x01, 0xFF, 0xFF, 0x00, 0x80])
    XCTAssertEqual(samples, [256, -1, -32768])
  }

  func testOddLengthIsRejected() {
    XCTAssertThrowsError(try AudioDecoder.decodeUncompressed([0x00, 0x01, 0x02]))
  }

  /// Config nibbles: low = bits dropped per sample, high = unary escape length.
  func testRiceHeaderParsing() throws {
    // config 0x84 -> shift 4, maxUnary 8, width 12; the values a real ring emits.
    var payload: [UInt8] = [0x84]
    payload += [0x10, 0x00, 0x00, 0x00]            // bitCount = 16
    payload += [0x0D, 0x27, 0x00, 0x00]            // sampleRateHz = 9997
    payload += [UInt8](repeating: 0xFF, count: 4)  // bitstream
    let record = try RiceAudioRecord(payload: payload)
    XCTAssertEqual(record.shift, 4)
    XCTAssertEqual(record.maxUnary, 8)
    XCTAssertEqual(record.width, 12)
    XCTAssertEqual(record.sampleRateHz, 9997)
    XCTAssertEqual(record.bitCount, 16)
  }

  /// The predictor is second-order: a constant residual produces a *ramp*, not a
  /// constant. Single integration was the original bug and is audible as a click
  /// at every record join, so it is pinned down by a test.
  func testPredictorIsSecondOrder() throws {
    // shift 0 so the raw predictor values are visible; maxUnary 8.
    var payload: [UInt8] = [0x80]
    payload += [0x08, 0x00, 0x00, 0x00]            // 8 bits
    payload += [0x0D, 0x27, 0x00, 0x00]
    // `01` = magnitude 1, then a 0 sign bit = +1. Four of them: 01001001 00...
    payload += [0b0100_1001, 0b0010_0100]
    let audio = try RiceDecoder.decodeQuantised(payload: payload)
    // Residuals +1,+1 -> velocity 1,2 -> position 1,3 (quadratic, not linear).
    XCTAssertEqual(Array(audio.values.prefix(2)), [1, 3])
  }

  /// A leading 1 bit is a zero residual, so an all-ones bitstream decodes to
  /// silence -- the simplest end-to-end check of the bit reader and accumulator.
  func testAllOnesBitstreamDecodesToSilence() throws {
    var payload: [UInt8] = [0x84]
    payload += [0x20, 0x00, 0x00, 0x00]            // 32 bits
    payload += [0x0D, 0x27, 0x00, 0x00]
    payload += [UInt8](repeating: 0xFF, count: 4)
    let timeline = try AudioDecoder.decodeRice(payload)
    XCTAssertEqual(timeline.samples.count, 32)
    XCTAssertTrue(timeline.samples.allSatisfy { $0 == 0 })
    XCTAssertEqual(timeline.sampleRateHz, 9997)
  }

  func testRiceRejectsPayloadShorterThanItsDeclaredBitstream() {
    var payload: [UInt8] = [0x84]
    payload += [0xFF, 0xFF, 0x00, 0x00]            // claims 65535 bits
    payload += [0x0D, 0x27, 0x00, 0x00]
    payload += [0x00, 0x00]                        // but holds 16
    XCTAssertThrowsError(try AudioDecoder.decodeRice(payload))
  }

  func testDCBiasRemovalCentresSamples() {
    let centred = DCBias.removed(from: [1000, 1002, 998, 1000])
    XCTAssertEqual(centred, [0, 2, -2, 0])
  }

  func testWAVHeaderIsWellFormed() {
    let wav = WAVWriter.data(samples: [0, 1, -1], sampleRateHz: 16000)
    XCTAssertEqual(wav.count, 44 + 6)
    XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
    XCTAssertEqual(Array(wav[8 ..< 12]), Array("WAVE".utf8))
  }
}
