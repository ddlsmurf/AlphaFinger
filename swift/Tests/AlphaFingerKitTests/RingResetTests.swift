import XCTest
@testable import AlphaFingerKit

/// The failure this guards against is silent: a ring that has restarted its
/// numbering serves indices the client has already "seen", so it fetches nothing
/// and looks perfectly healthy while losing every recording.
///
/// Values come from a live session: on a reset the advertised count falls 11 -> 0
/// with the fingerprint unchanged, and the window restarts at {0, 0}.
final class RingResetTests: XCTestCase {
  private let fingerprint: UInt32 = 0xD8B9_FFFF

  /// Builds the 8-byte CoreBluetooth form: company identifier then payload.
  private func advertisement(count: UInt8, fingerprint: UInt32) throws
    -> RingAdvertisement {
    var bytes: [UInt8] = [0xEA, 0x0E]
    bytes += withUnsafeBytes(of: fingerprint.littleEndian) { [UInt8]($0) }
    bytes += [count, 0x00]
    return try RingAdvertisement(manufacturerData: bytes)
  }

  // MARK: - The conclusive detector

  func testWindowBelowCursorIsAReset() {
    let evidence = RingResetDetector.evidence(rangeEnd: 0, cursor: 11)
    XCTAssertEqual(evidence, .collectionWindowFell(rangeEnd: 0, cursor: 11))
    XCTAssertTrue(evidence?.isConclusive ?? false)
  }

  func testEvictionIsNotAReset() {
    // rangeStart 68 with the cursor at 11 is the eviction case:
    // the window moved *forward* past us. Recordings were lost, but the numbering
    // is intact and the cursor must survive.
    XCTAssertNil(RingResetDetector.evidence(rangeEnd: 546, cursor: 11))
  }

  func testNoCursorMeansNothingToInvalidate() {
    XCTAssertNil(RingResetDetector.evidence(rangeEnd: 0, cursor: nil))
  }

  func testWindowAtTheCursorIsNotAReset() {
    XCTAssertNil(RingResetDetector.evidence(rangeEnd: 11, cursor: 11))
  }

  // MARK: - The advertisement suspicion

  func testAdvertisedCountFallingIsSuspiciousAfterCorroboration() throws {
    let detector = RingResetDetector()
    XCTAssertNil(detector.observe(try advertisement(count: 11,
                                                    fingerprint: fingerprint)))
    // One low sighting is not enough: advertisements are unauthenticated.
    XCTAssertNil(detector.observe(try advertisement(count: 0,
                                                    fingerprint: fingerprint)))
    let evidence = detector.observe(try advertisement(count: 0,
                                                      fingerprint: fingerprint))
    XCTAssertEqual(evidence, .advertisedCountFell(fingerprint: fingerprint,
                                                  previous: 11, now: 0))
    XCTAssertFalse(evidence?.isConclusive ?? true,
                   "an advertisement must never be allowed to invalidate the cursor")
  }

  func testChangedFingerprintIsNotAReset() throws {
    let detector = RingResetDetector()
    _ = detector.observe(try advertisement(count: 11, fingerprint: fingerprint))
    // A different ring, or the same one reprogrammed for another user.
    XCTAssertNil(detector.observe(try advertisement(count: 0,
                                                    fingerprint: 0x1234_5678)))
    XCTAssertNil(detector.observe(try advertisement(count: 0,
                                                    fingerprint: 0x1234_5678)))
  }

  func testCountWrapIsNotAReset() throws {
    let detector = RingResetDetector()
    _ = detector.observe(try advertisement(count: 255, fingerprint: fingerprint))
    // rawCollectionCount is a u8 and its truncation rule is unverified,
    // so 255 -> 0 is at least as likely to be a wrap.
    XCTAssertNil(detector.observe(try advertisement(count: 0,
                                                    fingerprint: fingerprint)))
    XCTAssertNil(detector.observe(try advertisement(count: 0,
                                                    fingerprint: fingerprint)))
  }

  func testRisingCountIsNormal() throws {
    let detector = RingResetDetector()
    for count in UInt8(0) ... UInt8(11) {
      XCTAssertNil(detector.observe(try advertisement(count: count,
                                                      fingerprint: fingerprint)))
    }
  }

  // MARK: - The cursor contract

  func testInvalidateClearsThePosition() throws {
    let cursor = InMemoryCollectionCursor()
    try cursor.markCompleted(throughIndex: 546)
    XCTAssertTrue(cursor.hasSeen(546))
    try cursor.invalidate(reason: "test")
    XCTAssertNil(cursor.lastCompletedIndex)
    XCTAssertFalse(cursor.hasSeen(0), "a reset ring restarts at 0")
  }

  func testMarkCompletedStaysMonotone() throws {
    let cursor = InMemoryCollectionCursor()
    try cursor.markCompleted(throughIndex: 10)
    try cursor.markCompleted(throughIndex: 4)
    XCTAssertEqual(cursor.lastCompletedIndex, 10,
                   "only invalidate() may move the cursor backwards")
  }

  // MARK: - The company-identifier gate

  func testManufacturerDataGate() {
    XCTAssertTrue(RingAdvertisement.hasRingCompanyIdentifier(
      [0xEA, 0x0E, 0xFF, 0xFF, 0xB9, 0xD8, 0x00, 0x00]))
    XCTAssertFalse(RingAdvertisement.hasRingCompanyIdentifier(
      [0x4C, 0x00, 0xFF, 0xFF, 0xB9, 0xD8, 0x00, 0x00]), "Apple's company ID")
    XCTAssertFalse(RingAdvertisement.hasRingCompanyIdentifier([0xEA, 0x0E]),
                   "identifier present but no payload")
    XCTAssertFalse(RingAdvertisement.hasRingCompanyIdentifier([]))
  }

  // MARK: - The synthetic encoder must invert the decoder

  /// The fixtures the pipeline tests run on are generated, so the generator has
  /// to be right. Encoding a known waveform and decoding it back checks the
  /// decoder against something reproducible, which fixed blobs never could.
  func testRiceRoundTrip() throws {
    let original = SyntheticRing.tone(samples: 2000)
    let payload = SyntheticRing.encodeAudio(values: original)
    let decoded = try RiceDecoder.decodeQuantised(payload: payload)
    XCTAssertEqual(decoded.values, original,
                   "the encoder and decoder disagree, so every fixture is suspect")
    XCTAssertEqual(decoded.sampleRateHz, SyntheticRing.sampleRateHz)
    XCTAssertEqual(decoded.shift, SyntheticRing.shift)
  }

  /// Exercises the escape path, which a smooth tone never reaches: a residual too
  /// large for the unary run has to survive as a literal.
  func testRiceRoundTripWithLargeJumps() throws {
    let modulus = Int32(1 << SyntheticRing.width)
    let original: [Int32] = [0, 900, 12, 4000, 7, 2048, 1, modulus - 1, 500]
    let payload = SyntheticRing.encodeAudio(values: original)
    XCTAssertEqual(try RiceDecoder.decodeQuantised(payload: payload).values, original)
  }

  /// A generated collection must satisfy the same validator the transport uses
  /// to reject a corrupted transfer.
  func testSyntheticCollectionIsWellFormed() throws {
    let bytes = SyntheticRing.part(startIndex: 0, isMultiPart: true, isFinalPart: false,
                                   pressSequence: 0x1, pressCount: 1,
                                   unixTime: 1_787_476_150, samples: 400)
    XCTAssertTrue(CollectionParser.isWellFormed(bytes))
    let collection = try RingCollection(index: 0, bytes: bytes)
    XCTAssertEqual(collection.deviceIdentifier, "000000000001")
    XCTAssertEqual(collection.batteryMilliVolts, 1579)
    XCTAssertEqual(collection.multipartInfo?.isFinalPart, false)
  }

  // MARK: - Record decoders, against real capture bytes

  /// Builds a collection holding one record, the way the ring frames them.
  private func collection(recordType: UInt8, payload: [UInt8]) throws
    -> RingCollection {
    let record: [UInt8] = [recordType, UInt8(payload.count), 0x00] + payload
    let total = UInt32(record.count + 4)
    let header: [UInt8] = [UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF),
                           UInt8((total >> 16) & 0xFF), UInt8((total >> 24) & 0xFF)]
    return try RingCollection(index: 0, bytes: header + record)
  }

  /// These payloads are copied out of `captures/extracted/third/*.bin`. Every one
  /// of these decoders previously required more bytes than the ring actually
  /// sends, so all three silently returned nil and the values never reached a
  /// sidecar. A test with real bytes would have caught it immediately.
  func testBatteryDecodesFromRealBytes() throws {
    let collection = try collection(recordType: RecordType.batteryVoltage.rawValue,
                                    payload: [0x2b, 0x06])
    XCTAssertEqual(collection.batteryMilliVolts, 1579)
  }

  func testLifetimeCollectionCountDecodesFromRealBytes() throws {
    let collection = try collection(
      recordType: RecordType.lifetimeCollectionCount.rawValue,
      payload: [0x00, 0x04, 0x00, 0x00])
    XCTAssertEqual(collection.lifetimeCollectionCount, 1024)
  }

  func testPlatformVersionsDecodesFromRealBytes() throws {
    let collection = try collection(recordType: RecordType.platformVersions.rawValue,
                                    payload: [0x0b, 0x00, 0x03, 0x4b])
    XCTAssertEqual(collection.platformVersions, "hw 11.0 fw 3.75")
  }

  func testShortPayloadsStillReturnNilRatherThanCrashing() throws {
    let collection = try collection(recordType: RecordType.batteryVoltage.rawValue,
                                    payload: [0x2b])
    XCTAssertNil(collection.batteryMilliVolts)
  }

  // MARK: - Connecting only when the ring asks

  private func gateDecision(count: UInt8, needsServicing: Bool,
                            history: ConnectionGate.History) throws
    -> ConnectionGate.Decision {
    var bytes: [UInt8] = [0xEA, 0x0E]
    bytes += withUnsafeBytes(of: fingerprint.littleEndian) { [UInt8]($0) }
    bytes += [count, needsServicing ? 0x40 : 0x00]
    return ConnectionGate().decide(
      advertisement: try RingAdvertisement(manufacturerData: bytes),
      history: history)
  }

  func testConnectsWhenTheRingAsks() throws {
    let history = ConnectionGate.History(lastFetchedCount: 11, lastFetchedAt: Date())
    XCTAssertTrue(try gateDecision(count: 11, needsServicing: true,
                                   history: history).shouldConnect)
  }

  func testStaysAwayWhenThereIsNothingToDo() throws {
    let history = ConnectionGate.History(lastFetchedCount: 11, lastFetchedAt: Date())
    // Exactly the state in which the app used to reconnect every 20 seconds for
    // nothing.
    XCTAssertEqual(try gateDecision(count: 11, needsServicing: false,
                                    history: history), .stayAway)
  }

  /// No timer backs this up any more, so the count comparison has to carry it.
  /// It is a standing difference rather than an edge: however long ago the last
  /// fetch was, a differing count still connects.
  func testCountDifferenceConnectsHoweverOldTheFetch() throws {
    let ancient = ConnectionGate.History(
      lastFetchedCount: 11,
      lastFetchedAt: Date(timeIntervalSince1970: 0))
    XCTAssertTrue(try gateDecision(count: 12, needsServicing: false,
                                   history: ancient).shouldConnect)
    // A ring reset counts backwards; missing that costs every recording on it.
    XCTAssertTrue(try gateDecision(count: 0, needsServicing: false,
                                   history: ancient).shouldConnect)
    // And an idle ring stays untouched no matter how long it has been.
    XCTAssertEqual(try gateDecision(count: 11, needsServicing: false,
                                    history: ancient), .stayAway)
  }

  func testConnectsWhenNothingHasEverBeenFetched() throws {
    XCTAssertTrue(try gateDecision(count: 0, needsServicing: false,
                                   history: ConnectionGate.History()).shouldConnect)
  }

  /// The launch path connects to a remembered peripheral without seeing an
  /// advertisement, so the count is nil while a fetch really did happen. That was
  /// logged as `advertisedCount: -1` and made the gate reconnect immediately.
  func testFetchedWithoutAnAdvertisementDoesNotForceAConnection() throws {
    let history = ConnectionGate.History(lastFetchedCount: nil, lastFetchedAt: Date())
    XCTAssertEqual(try gateDecision(count: 11, needsServicing: false,
                                    history: history), .stayAway)
  }

  // MARK: - "Nearby" must mean an advertisement actually arrived

  /// The regression: the timestamp used to double as the scan watchdog's seed, so
  /// starting a scan refreshed it. Since the watchdog restarts the scan every ten
  /// seconds, it was never stale and the menu claimed the ring was nearby from
  /// launch, in sessions where no advertisement ever arrived.
  func testNeverHeardIsNotNearby() {
    XCTAssertFalse(RingPresence.isNearby(lastHeard: nil, now: Date()))
    // What a session that has never heard a ring actually holds.
    XCTAssertFalse(RingPresence.isNearby(lastHeard: .distantPast, now: Date()))
  }

  func testRecentlyHeardIsNearby() {
    let now = Date()
    XCTAssertTrue(RingPresence.isNearby(lastHeard: now.addingTimeInterval(-10), now: now))
  }

  func testLongSilenceIsNotNearby() {
    let now = Date()
    XCTAssertFalse(RingPresence.isNearby(lastHeard: now.addingTimeInterval(-90), now: now),
                   "the ring left; the menu must stop claiming it is here")
  }

  // MARK: - Not re-fetching what this connection already has

  /// The cursor only advances once a whole recording is filed, so mid-recording it
  /// never moves and every drain round would restart from the beginning. One
  /// measured session issued 52 reads for 28 collections.
  func testFetchedSetSkipsOnlyWhatSucceeded() {
    var fetched: Set<UInt32> = []
    var reads: [UInt32] = []

    /// Mirrors the loop in `LiveRingSource.poll`: the cursor is stuck at nil, so
    /// the set is the only thing preventing a re-read.
    func drain(upTo end: UInt32, failing: Set<UInt32> = []) {
      for index in 0 ..< end where !fetched.contains(index) {
        reads.append(index)
        // Recorded only after a successful, validated read.
        if !failing.contains(index) { fetched.insert(index) }
      }
    }

    drain(upTo: 8)                        // round 0
    drain(upTo: 16, failing: [12])        // round 1 -- 12 fails
    drain(upTo: 28)                       // round 2

    XCTAssertEqual(reads.filter { $0 == 3 }.count, 1, "index 3 was re-read")
    XCTAssertEqual(reads.filter { $0 == 12 }.count, 2,
                   "a failed read must stay eligible for a retry")
    XCTAssertEqual(reads.count, 29, "28 collections plus one retry")
    XCTAssertEqual(Set(reads).count, 28)
  }

  // MARK: - Command output

  /// A command's output is the only evidence of why it failed, so every line has
  /// to survive into the log, tagged with the stream it came from.
  func testOutputIsSplitIntoTaggedLines() throws {
    let outcome = try ShellAction().run(
      command: "echo one; echo two; echo problem >&2; exit 3", environment: [:])
    XCTAssertEqual(outcome.exitCode, 3)
    XCTAssertFalse(outcome.succeeded)

    // Order *within* a stream is guaranteed; order *between* them is not, and
    // asserting it made this test fail about two runs in three. The three writes
    // land microseconds apart on two reader threads, so which timestamp is lower
    // is a coin toss -- and a reader on the far end of two pipes genuinely cannot
    // recover the order they were written in. `testStreamsAreInterleavedInTimeOrder`
    // covers the case that *is* determinate, with real gaps between the writes.
    XCTAssertEqual(outcome.outputLines.filter { $0.stream == "stdout" }.map(\.line),
                   ["one", "two"])
    XCTAssertEqual(outcome.outputLines.filter { $0.stream == "stderr" }.map(\.line),
                   ["problem"])
    XCTAssertEqual(outcome.outputLines.count, 3, "nothing lost or duplicated")
  }

  func testBlankOutputProducesNoLines() throws {
    let outcome = try ShellAction().run(command: "true", environment: [:])
    XCTAssertTrue(outcome.succeeded)
    XCTAssertTrue(outcome.outputLines.isEmpty,
                  "a silent command must not add noise to the log")
  }

  /// The timeout used to be unreachable: both pipes were read to end-of-file
  /// before the deadline loop ran, and that read only returns when the command
  /// exits. A hung script would hold the caller for as long as it liked.
  func testATimeoutActuallyStopsTheCommand() throws {
    let started = Date()
    let outcome = try ShellAction().run(command: "sleep 30", environment: [:],
                                        timeoutSeconds: 0.5)
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertFalse(outcome.succeeded, "a killed command has not succeeded")
    XCTAssertLessThan(elapsed, 10,
                      "the deadline must be enforced while the command runs")
  }

  /// Every output line used to carry the moment the command exited, so a run that
  /// took seconds looked instantaneous. Each line must carry when it arrived.
  func testOutputLinesAreStampedAsTheyArrive() throws {
    let outcome = try ShellAction().run(
      command: "echo one; sleep 0.5; echo two", environment: [:])
    XCTAssertEqual(outcome.outputLines.map(\.line), ["one", "two"])
    let gap = outcome.outputLines[1].at.timeIntervalSince(outcome.outputLines[0].at)
    XCTAssertGreaterThan(gap, 0.4, "both lines were stamped at the same moment")
  }

  /// A chunk that ends without a newline is still a line -- the command exited
  /// without one, not with nothing to say.
  func testOutputWithoutATrailingNewlineStillArrives() throws {
    let outcome = try ShellAction().run(command: "printf 'no newline'", environment: [:])
    XCTAssertEqual(outcome.outputLines.map(\.line), ["no newline"])
  }

  /// The streams are read on separate threads, so the merged order has to come
  /// from the timestamps rather than from which thread finished first.
  func testStreamsAreInterleavedInTimeOrder() throws {
    let outcome = try ShellAction().run(
      command: "echo first; sleep 0.3; echo middle >&2; sleep 0.3; echo last",
      environment: [:])
    XCTAssertEqual(outcome.outputLines.map(\.line), ["first", "middle", "last"])
    XCTAssertEqual(outcome.outputLines.map(\.stream), ["stdout", "stderr", "stdout"])
  }

  /// The log says what a command cost, so the number has to be the command's own
  /// run time rather than anything the caller measures around it.
  func testOutcomeReportsHowLongItTook() throws {
    let outcome = try ShellAction().run(command: "sleep 0.3", environment: [:])
    XCTAssertGreaterThanOrEqual(outcome.durationSeconds, 0.3)
    XCTAssertLessThan(outcome.durationSeconds, 3, "should be the sleep, not the suite")
  }

  /// Output written before the deadline still has to arrive: the readers run
  /// alongside the command rather than after it.
  func testOutputSurvivesATimeout() throws {
    let outcome = try ShellAction().run(command: "echo spoke; sleep 30",
                                        environment: [:], timeoutSeconds: 0.5)
    XCTAssertEqual(outcome.outputLines.map(\.line), ["spoke"])
  }

  // MARK: - Classifying a pairing refusal

  /// The two ATT codes mean opposite things and need opposite responses. The
  /// probe draws 0x05 on an unbonded link, which is what makes CoreBluetooth start
  /// SMP; 0x0F was observed 8 times out of 8 while a phone held the ring's bond,
  /// and macOS does not pair on it.
  func testInsufficientEncryptionIsABondConflict() {
    XCTAssertEqual(RingSession.classifyProbeFailure(attCode: 0x0F),
                   .bondHeldElsewhere)
  }

  func testInsufficientAuthenticationIsAnOrdinaryPairingFailure() {
    XCTAssertEqual(RingSession.classifyProbeFailure(attCode: 0x05),
                   .ordinaryPairingFailure)
  }

  func testOtherErrorsAreOrdinaryPairingFailures() {
    XCTAssertEqual(RingSession.classifyProbeFailure(attCode: 0x0E),
                   .ordinaryPairingFailure)
    XCTAssertEqual(RingSession.classifyProbeFailure(attCode: nil),
                   .ordinaryPairingFailure)
  }

  // MARK: - Staying connected while the ring records

  func testKeepsDrainingWhileRecording() {
    let decision = DrainPolicy().decide(.init(
      recordingInProgress: true, windowGrew: false, rounds: 1, elapsed: 5))
    XCTAssertTrue(decision.shouldKeepDraining,
                  "hanging up mid-recording cost 59 s to reconnect")
  }

  func testKeepsDrainingWhenMoreAppeared() {
    XCTAssertTrue(DrainPolicy().decide(.init(
      recordingInProgress: false, windowGrew: true,
      rounds: 1, elapsed: 5)).shouldKeepDraining)
  }

  func testHangsUpWhenFinished() {
    XCTAssertFalse(DrainPolicy().decide(.init(
      recordingInProgress: false, windowGrew: false,
      rounds: 1, elapsed: 5)).shouldKeepDraining)
  }

  /// Both bounds are load-bearing: a ring that never sends a final part would
  /// otherwise hold the link open indefinitely, which is the whole thing this
  /// design spends sparingly.
  func testTimeBoundWinsOverAnUnfinishedRecording() {
    XCTAssertFalse(DrainPolicy().decide(.init(
      recordingInProgress: true, windowGrew: true,
      rounds: 1, elapsed: DrainPolicy.maximumHold)).shouldKeepDraining)
  }

  func testRoundBoundWinsOverAnUnfinishedRecording() {
    XCTAssertFalse(DrainPolicy().decide(.init(
      recordingInProgress: true, windowGrew: true,
      rounds: DrainPolicy.maximumRounds, elapsed: 1)).shouldKeepDraining)
  }

  // MARK: - Refusing to file into the Trash

  /// A bookmark follows its folder into the Trash, so a deleted recordings folder
  /// silently redirects recordings there and emptying the Trash destroys them.
  func testTrashPathsAreRecognised() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    XCTAssertTrue(RecordingWriter.isInTrash(
      home.appendingPathComponent(".Trash/AlphaFingerRecordings")))
    XCTAssertTrue(RecordingWriter.isInTrash(
      URL(fileURLWithPath: "/Volumes/Backup/.Trashes/501/Recordings")))
    XCTAssertFalse(RecordingWriter.isInTrash(
      home.appendingPathComponent("Documents/AlphaFingerRecordings")))
    XCTAssertFalse(RecordingWriter.isInTrash(
      home.appendingPathComponent("Documents/TrashTalk")),
      "a folder merely named like the Trash is fine")
  }

  // MARK: - Splicing across a reset

  /// A non-final multipart part, so the run stays open.
  private func openingPart(index: UInt32, startIndex: UInt32) throws
    -> RingCollection {
    let payload: [UInt8] = [
      UInt8(startIndex & 0xFF), UInt8((startIndex >> 8) & 0xFF),
      UInt8((startIndex >> 16) & 0xFF), UInt8((startIndex >> 24) & 0xFF),
      0x01,   // isMultiPart
      0x00,   // isFinalPart == false, so the assembler keeps waiting
    ]
    let record: [UInt8] = [RecordType.collectionMultiPartInfo.rawValue,
                           UInt8(payload.count), 0x00] + payload
    let total = UInt32(record.count + 4)
    let header: [UInt8] = [UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF),
                           UInt8((total >> 16) & 0xFF), UInt8((total >> 24) & 0xFF)]
    return try RingCollection(index: index, bytes: header + record)
  }

  /// The bug that shipped: the app called a full flush after every collection, so
  /// a multipart run was closed part-by-part instead of being joined.
  func testEndOfBatchLeavesAnOpenRunOpen() throws {
    let assembler = CollectionAssembler()
    for index in UInt32(0) ... UInt32(3) {
      XCTAssertTrue(assembler.accept(try openingPart(index: index, startIndex: 0)).isEmpty,
                    "part \(index) closed the run early")
      // What the live source now does between parts. It must not close the run.
      XCTAssertTrue(assembler.flushRunsIdle(longerThan: 300).isEmpty,
                    "end-of-batch closed a run that is still being fetched")
    }
    let closed = assembler.flush()
    XCTAssertEqual(closed.count, 1, "expected one joined run, got \(closed.count)")
    XCTAssertEqual(closed.first?.collections.count, 4,
                   "all four parts must land in the same recording")
  }

  /// The backstop for a run whose final part never arrives.
  func testStalledRunIsFlushedEventually() throws {
    var clock = Date(timeIntervalSince1970: 1_787_476_150)
    let assembler = CollectionAssembler(now: { clock })
    _ = assembler.accept(try openingPart(index: 0, startIndex: 0))

    XCTAssertTrue(assembler.flushRunsIdle(longerThan: 300).isEmpty,
                  "a fresh run must not be flushed")
    clock = clock.addingTimeInterval(301)
    let closed = assembler.flushRunsIdle(longerThan: 300)
    XCTAssertEqual(closed.count, 1,
                   "a run with no new parts for 5 minutes must be written anyway")
  }

  /// The cursor only advances once a whole recording is filed, so every
  /// reconnection re-reads the open run from its start. Those repeats must be
  /// ignored -- treating a lower index as a restart closed the run early and split
  /// one recording across two files.
  func testDuplicatePartsAreIgnored() throws {
    let assembler = CollectionAssembler()
    for index in UInt32(0) ... UInt32(2) {
      XCTAssertTrue(assembler.accept(try openingPart(index: index, startIndex: 0)).isEmpty)
    }
    // The ring dropped the link; the next cycle re-reads from the beginning.
    for index in UInt32(0) ... UInt32(2) {
      XCTAssertTrue(assembler.accept(try openingPart(index: index, startIndex: 0)).isEmpty,
                    "a re-read part closed the run")
    }
    let closed = assembler.flush()
    XCTAssertEqual(closed.count, 1, "expected one run, got \(closed.count)")
    XCTAssertEqual(closed.first?.collections.count, 3,
                   "re-read parts were added twice: \(closed.first?.indices ?? [])")
  }

  /// A genuine reset renumbers from 0, and index 0 then collides with a part
  /// already held. The explicit reset signal is what separates the two cases.
  func testResetClearsTheAssemblerSoIndexZeroIsAcceptedAgain() throws {
    let assembler = CollectionAssembler()
    _ = assembler.accept(try openingPart(index: 0, startIndex: 0))
    _ = assembler.accept(try openingPart(index: 1, startIndex: 0))

    // What RingPipeline.ringDidReset does: close everything, then forget.
    let stranded = assembler.flush()
    assembler.ringDidReset()
    XCTAssertEqual(stranded.count, 1, "the pre-reset run must be written out")

    let afterReset = assembler.accept(try openingPart(index: 0, startIndex: 0))
    XCTAssertTrue(afterReset.isEmpty, "post-reset part opened a run")
    let closed = assembler.flush()
    XCTAssertEqual(closed.first?.collections.count, 1,
                   "the post-reset part must not have joined the old run")
  }
}
