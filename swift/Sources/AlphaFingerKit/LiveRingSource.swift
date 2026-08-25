#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// Pulls collections off a real ring over BLE.
///
/// One request at
/// a time because the ring answers on the control channel and then streams the
/// payload on the data channel:
///
/// 1. `PROGRAM 0x40030001` — set the ring's clock. Recording timestamps come from
///    it, and they are what files get named after.
/// 2. `READ 0x40030005` — the window of collection indices currently stored.
/// 3. For each index past the cursor, `READ (0x40020000 + index)` with
///    **length 0**, which both reports the size and makes the ring stream it.
///
/// **Untested against hardware.** Everything above this class is verified by
/// replaying a captured session; this is the one layer that cannot be, so it is
/// deliberately the only place a live failure can originate.
public final class LiveRingSource: NSObject, RingSource, @unchecked Sendable {
  public var onCollection: ((RingCollection) -> Void)?
  public var onError: ((Error) -> Void)?
  /// Fires on connection state changes, for the menu.
  public var onConnectionChange: ((Bool) -> Void)?
  /// Fires with the ring's battery, in millivolts, each time one is read.
  ///
  /// Only ever as fresh as the last fetch: battery is carried in collections, not
  /// in the advertisement, and this client never connects just to look.
  public var onBattery: ((UInt16) -> Void)?
  /// When the ring was last heard from, whether or not we acted on it.
  public var lastAdvertisementDate: Date? { session?.lastAdvertisementDate }
  /// Fires when an advertisement was seen and deliberately not acted on, so the
  /// UI can say "nearby, nothing to send" rather than looking stalled.
  public var onIdle: (() -> Void)?
  /// The ring has nothing pending and is not recording. Fires on every such
  /// advertisement, several times a second, so handlers must be cheap.
  public var onRingIdle: (() -> Void)?
  /// Fires when a poll cycle has taken everything the ring currently offers.
  ///
  /// The signal a consumer needs to act on pending gestures without prematurely
  /// closing a multipart run that the next connection will finish.
  public var onBatchComplete: (() -> Void)?
  /// Fires when the ring restarted its collection numbering. The cursor has
  /// already been invalidated by the time this is called.
  public var onRingReset: ((RingResetEvidence) -> Void)?
  /// Fires once the ring is chosen, so the app can persist its identifier.
  public var onPeripheralIdentified: ((UUID) -> Void)?
  /// What tying the cursor to this ring decided. Worth logging: a different ring
  /// means everything it holds is about to be fetched from the start.
  public var onCursorAdoption: ((CursorAdoption) -> Void)?
  /// Fires when the ring has discarded collections the client never fetched.
  ///
  /// The ring evicts its oldest collections once it fills -- a captured session
  /// showed the window starting at 68 rather than 0 -- so a client that is away
  /// long enough loses recordings. That is worth saying out loud rather than
  /// letting the count quietly not add up.
  public var onCollectionsMissed: ((_ count: UInt32, _ oldestAvailable: UInt32) -> Void)?
  /// Fires on every connection phase change, so the UI can distinguish "still
  /// connecting" from "stuck before pairing".
  public var onPhaseChange: ((RingSession.Phase) -> Void)?
  /// Fires when the ring would not bond. Needs the user, not a retry loop.
  public var onPairingFailed: ((Error) -> Void)?

  public enum TransferError: Error, CustomStringConvertible {
    case timedOut(String)
    case ringReportedFailure(status: UInt32, address: UInt32)
    case shortTransfer(expected: UInt32, received: Int)
    case malformedCollection(index: UInt32, bytes: Int)
    case linkDropped(String)

    public var description: String {
      switch self {
      case let .timedOut(what):
        return "ring did not answer in time: \(what)"
      case let .ringReportedFailure(status, address):
        return String(format: "ring returned status %u for address 0x%08X", status, address)
      case let .shortTransfer(expected, received):
        return "transfer ended early: expected \(expected) bytes, received \(received)"
      case let .malformedCollection(index, bytes):
        return "collection \(index) did not validate (\(bytes) bytes); the stream is "
          + "probably misaligned after an interrupted transfer"
      case let .linkDropped(what):
        return "the ring dropped the link during \(what)"
      }
    }
  }

  /// How long to wait for a control response, or for a payload to finish arriving.
  public static let responseTimeout: TimeInterval = 10
  /// Gap after the last data notification that means the payload is complete,
  /// used only as a backstop -- the announced byte count is the real signal.
  public static let quietPeriod: TimeInterval = 1.0
  /// A collection that fails to validate is re-read this many times before the
  /// poll cycle gives up on it and tries again next time round.
  public static let collectionAttempts = 2

  private let capture: CaptureLog
  private let cursor: CollectionCursor?
  private let pollInterval: TimeInterval
  private let knownRing: UUID?
  private var session: RingSession?
  private var timer: DispatchSourceTimer?
  private let queue = DispatchQueue(label: "alphafinger.live")

  // Set while a single request is in flight.
  private var pendingResponse: TelestoResponse?
  private var dataBuffer: [UInt8] = []
  private let signal = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  /// Bumped on every disconnect.
  ///
  /// An exchange that spans a link drop must fail rather than resume: the bytes
  /// already buffered belong to the dead connection, and letting them run into
  /// the next request's payload is exactly the misalignment the collection
  /// validator was written to catch.
  private var linkGeneration: UInt64 = 0
  /// What the gate needs to decide whether the next advertisement is worth acting
  /// on. Kept here rather than in the session because it is fetch history, not
  /// connection state.
  private var history = ConnectionGate.History()
  /// Collections delivered in the current cycle, so an empty cycle can hang up.
  private var deliveredThisCycle = 0
  /// Indices already delivered on this connection.
  ///
  /// The cursor only advances once a whole recording is *filed*, so mid-recording
  /// nothing has advanced and every drain round would otherwise restart from
  /// `rangeStart`. In one measured session that made 52 reads for 28 collections,
  /// indices 0-3 fetched three times each -- 46% of the radio time wasted while
  /// the ring was busy recording.
  private var fetchedThisConnection: Set<UInt32> = []
  private let drainPolicy = DrainPolicy()
  /// `rangeEnd` from the last window read, which is what the gate compares against.
  private var lastWindowEnd: UInt16?

  /// `knownRing` is the identifier of a ring we have connected to before, if any.
  /// Supplying it skips scanning entirely -- CoreBluetooth can connect straight to
  /// a retrieved peripheral and keeps the request pending until it is in range.
  public init(capture: CaptureLog, cursor: CollectionCursor?,
              pollInterval: TimeInterval, knownRing: UUID? = nil) {
    self.capture = capture
    self.cursor = cursor
    self.pollInterval = pollInterval
    self.knownRing = knownRing
    super.init()
  }

  public func start() {
    let session = RingSession(capture: capture, target: nil,
                              preferred: knownRing) { [weak self] _ in
      guard let self else { return }
      self.onConnectionChange?(true)
      self.schedulePolling()
      // Fetch straight away rather than waiting for the next tick. The ring drops
      // an idle link after about 10 s (measured 10.08 s and 10.06 s from ready to
      // disconnect), so on a 20 s timer the connection is usually already dead by
      // the time the timer fires -- the client reconnected constantly and never
      // read anything.
      self.queue.async { self.poll() }
    }
    session.onTelestoResponse = { [weak self] response in
      self?.deliver(response)
    }
    session.onDataBytes = { [weak self] bytes in
      self?.appendData(bytes)
    }
    session.onPhaseChange = { [weak self] phase in
      self?.onPhaseChange?(phase)
    }
    session.onPairingFailed = { [weak self] error in
      self?.onPairingFailed?(error)
    }
    session.connectionHistory = { [weak self] in
      self?.history ?? ConnectionGate.History()
    }
    session.onStayedAway = { [weak self] _ in
      // Not an error: the ring is nearby and has nothing to hand over.
      self?.onIdle?()
    }
    session.onRingIdle = { [weak self] _ in
      self?.onRingIdle?()
    }
    session.onPeripheralIdentified = { [weak self] identifier in
      guard let self else { return }
      // Synchronously, here, before anything is fetched. The application's own
      // handler hops to the main actor, and a position belonging to another ring
      // makes every index below it read as already handled -- so the client would
      // quietly fetch nothing. That is not a race worth running.
      do {
        let adoption = try self.cursor?.adopt(ring: identifier)
        if let adoption { self.onCursorAdoption?(adoption) }
      } catch {
        self.onError?(error)
      }
      self.onPeripheralIdentified?(identifier)
    }
    session.onDisconnect = { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.linkGeneration &+= 1
      self.dataBuffer = []
      // A new connection re-reads whatever the cursor still has not covered.
      self.fetchedThisConnection = []
      self.lock.unlock()
      // Wake anything blocked in `exchange`. Without this a drop costs the full
      // response timeout, and with a standing connect the link is usually back
      // long before that expires.
      self.signal.signal()
      self.onConnectionChange?(false)
    }
    self.session = session
  }

  /// Retries pairing by reconnecting; see `RingSession.reconnect`.
  public func retryPairing() {
    session?.reconnect()
  }

  public func stop() {
    timer?.cancel()
    timer = nil
    session?.disconnect()
    session = nil
  }

  /// Arms the periodic poll.
  ///
  /// This is now only a safety net: the real trigger is becoming ready, which
  /// happens on every reconnection. The timer covers the case where the link
  /// stays up and idle for a long time.
  ///
  /// Settings says as much to the user, under "Idle link check": that changing it
  /// cannot make recordings arrive sooner. If this ever becomes load-bearing
  /// again, that caption turns into a lie and has to change with it.
  private func schedulePolling() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
    timer.setEventHandler { [weak self] in self?.poll() }
    self.timer = timer
    timer.resume()
  }

  private func poll() {
    guard let session, session.isReady else { return }
    do {
      // The ring's clock drifts, so it is reset before every batch.
      let (clockRequest, clockPayload) = TelestoRequest.syncClock()
      _ = try exchange(clockRequest, payload: clockPayload, on: session)

      let startedAt = Date()
      var rounds = 0
      var previousEnd: UInt16 = 0
      var recordingInProgress = false

      // Keep draining on this connection for as long as the ring is still
      // producing. Hanging up mid-recording and coming back cost 59 s once; every
      // healthy connect takes under 2 s.
      while true {
      let window = try exchange(.readStoredCollectionIndexes, on: session)
      guard window.payload.count >= 4 else {
        throw TransferError.shortTransfer(expected: 4, received: window.payload.count)
      }
      let reader = ByteReader(window.payload)
      let rangeStart = try reader.u16(at: 0, "storedCollectionIndexes.rangeStart")
      let rangeEnd = try reader.u16(at: 2, "storedCollectionIndexes.rangeEnd")
      capture.append("collectionWindow", ["rangeStart": Int(rangeStart),
                                          "rangeEnd": Int(rangeEnd),
                                          "round": rounds])
      let windowGrew = rounds > 0 && rangeEnd > previousEnd
      previousEnd = rangeEnd
      lastWindowEnd = rangeEnd

      // A ring that has been reset restarts its numbering at 0, so every index
      // compares as already seen and the client would quietly stop fetching for
      // good. Checked before the eviction test below: both look like the window
      // moving, but they move in opposite directions and need opposite responses.
      // First round only. These describe the state we arrived to; re-running them
      // every round would report the same eviction repeatedly and inflate the
      // count the menu shows.
      if rounds == 0,
         let evidence = RingResetDetector.evidence(rangeEnd: UInt32(rangeEnd),
                                                   cursor: cursor?.lastCompletedIndex) {
        capture.append("ringReset", [
          "evidence": String(describing: evidence),
          "rangeStart": Int(rangeStart),
          "rangeEnd": Int(rangeEnd),
          "cursor": cursor?.lastCompletedIndex.map(Int.init) ?? -1,
        ])
        // Uncaught on purpose: continuing with a cursor we failed to clear would
        // fetch nothing and look like a working client.
        try cursor?.invalidate(reason: String(describing: evidence))
        onRingReset?(evidence)
      }

      // `rangeStart` is not always 0: the ring discards its oldest collections
      // once storage fills. Anything below it is gone for good.
      if rounds == 0, let last = cursor?.lastCompletedIndex,
         UInt32(rangeStart) > last + 1 {
        let missed = UInt32(rangeStart) - (last + 1)
        capture.append("collectionsMissed", ["count": Int(missed),
                                             "oldestAvailable": Int(rangeStart),
                                             "cursor": Int(last)])
        onCollectionsMissed?(missed, UInt32(rangeStart))
      }

      // rangeEnd is EXCLUSIVE: a window of {0, 3}
      // is followed by reads of 0, 1 and 2 and never 3; {0, 0} is followed by no
      // read at all. Reading rangeEnd itself returns status 67 and, because that
      // throws, aborts the whole cycle -- which is what left recordings
      // half-fetched and re-read them on the next connection.
      // rangeEnd is EXCLUSIVE: a window of {0, 3} means 0, 1 and 2 exist, and
      // reading rangeEnd itself returns status 67.
      if rangeStart < rangeEnd {
        for index in UInt32(rangeStart) ..< UInt32(rangeEnd) {
          if cursor?.hasSeen(index) == true { continue }
          if fetchedThisConnection.contains(index) { continue }
          guard let bytes = try fetchCollection(index: index, on: session) else { continue }
          // Recorded only now, after the read succeeded and validated, so a
          // failed read stays eligible for the retry `fetchCollection` performs.
          fetchedThisConnection.insert(index)
          deliveredThisCycle += 1
          let collection = try RingCollection(index: index, bytes: bytes)
          // A non-final multipart part means the ring has more of this recording
          // coming: it is still being recorded right now.
          recordingInProgress = collection.multipartInfo.map { !$0.isFinalPart } ?? false
          if let millivolts = collection.batteryMilliVolts {
            capture.append("battery", ["milliVolts": Int(millivolts),
                                       "collection": Int(index)])
            onBattery?(millivolts)
          }
          onCollection?(collection)
        }
      }
      onBatchComplete?()

      rounds += 1
      let decision = drainPolicy.decide(.init(
        recordingInProgress: recordingInProgress, windowGrew: windowGrew,
        rounds: rounds, elapsed: Date().timeIntervalSince(startedAt)))
      guard case let .keepDraining(reason) = decision else {
        if case let .hangUp(why) = decision {
          capture.append("drainDone", ["reason": why, "rounds": rounds])
        }
        break
      }
      capture.append("keepDraining", ["reason": reason, "rounds": rounds])
      Thread.sleep(forTimeInterval: DrainPolicy.pollPause)
      guard session.isReady else { break }
      }

      finishCycle(on: session)
    } catch {
      // The cursor is untouched, so whatever was not read this cycle is simply
      // read next time.
      drainLateBytes()
      guard !session.isClosingDeliberately else {
        // We closed the link ourselves; reporting that as a failure would count
        // against `consecutiveFailures` and light the "can't reach the ring" icon
        // for something we did.
        capture.append("closedDuringExchange",
                       ["note": "link released while a request was in flight",
                        "error": String(describing: error)])
        return
      }
      onError?(error)
    }
  }

  /// Records what was fetched and releases the link.
  ///
  /// Holding an idle connection costs the ring radio time for nothing -- it must
  /// wake at every connection interval regardless of traffic -- so the link is
  /// given back as soon as there is nothing left to collect, and the next
  /// advertisement decides whether to take it again.
  private func finishCycle(on session: RingSession) {
    // The window, not the advertisement. `latestAdvertisement` is captured at
    // connect time and goes stale during a long recording -- in one session it
    // still said 3 while the window had reached 28, which made the very next
    // advertisement look like new data and forced a pointless reconnect.
    history = ConnectionGate.History(
      lastFetchedCount: lastWindowEnd.map { UInt8(truncatingIfNeeded: $0) },
      lastFetchedAt: Date())
    capture.append("cycleComplete", [
      "collections": deliveredThisCycle,
      "windowEnd": lastWindowEnd.map(Int.init) ?? -1,
    ])
    deliveredThisCycle = 0
    session.hangUp()
  }

  /// Reads one collection, rejecting a payload that does not validate.
  ///
  /// A transfer interrupted by a dropped link leaves bytes arriving late, which
  /// would otherwise be prepended to the *next* collection and silently corrupt
  /// it. The container is self-describing, so a bad blob is detectable: on
  /// failure the channel is drained and the read attempted once more.
  private func fetchCollection(index: UInt32, on session: RingSession) throws -> [UInt8]? {
    for attempt in 1 ... Self.collectionAttempts {
      let result = try exchange(.readCollection(index: index), on: session)
      if result.payload.isEmpty { return nil }
      if CollectionParser.isWellFormed(result.payload) { return result.payload }

      capture.append("malformedCollection", [
        "index": Int(index), "attempt": attempt,
        "bytes": result.payload.count,
        "note": "did not validate; draining the channel and retrying",
      ])
      guard attempt < Self.collectionAttempts else {
        throw TransferError.malformedCollection(index: index,
                                                bytes: result.payload.count)
      }
      drainLateBytes()
    }
    return nil
  }

  /// Waits out anything still in flight from an abandoned transfer and discards
  /// it, so the next read starts from a clean stream.
  private func drainLateBytes() {
    lock.lock()
    let alreadyEmpty = dataBuffer.isEmpty
    lock.unlock()
    // A disconnect already emptied the buffer, so there is nothing in flight to
    // wait out -- and this runs on the same queue as the poll timer.
    if !alreadyEmpty { Thread.sleep(forTimeInterval: Self.quietPeriod) }
    lock.lock()
    let discarded = dataBuffer.count
    dataBuffer = []
    lock.unlock()
    if discarded > 0 {
      capture.append("drainedLateBytes", ["bytes": discarded])
    }
  }

  /// Sends one request and waits for its response and payload.
  ///
  /// Serialised deliberately: the ring answers a request on one channel and
  /// streams its payload on another, so overlapping requests would make it
  /// impossible to tell which bytes belong to which.
  private func exchange(_ request: TelestoRequest, payload outgoing: [UInt8] = [],
                        on session: RingSession)
    throws -> (response: TelestoResponse, payload: [UInt8]) {
    // Drain any signal left over from a previous exchange. The semaphore counts,
    // and a disconnect signals it too, so a stray count would make this wait
    // return instantly with no response and desync every cycle after it -- which
    // is exactly what the 2026-08-23T152236Z capture shows: a failure logged 0 ms
    // after the write, before the ring's notification even arrived.
    while signal.wait(timeout: .now()) == .success {}

    lock.lock()
    pendingResponse = nil
    dataBuffer = []
    let generation = linkGeneration
    lock.unlock()

    let what = String(format: "0x%08X", request.address)
    try session.send(request, payload: outgoing)

    guard signal.wait(timeout: .now() + Self.responseTimeout) == .success else {
      throw TransferError.timedOut("control response for \(what)")
    }
    lock.lock()
    let response = pendingResponse
    let dropped = linkGeneration != generation
    lock.unlock()
    // The semaphore is signalled by a disconnect as well as by a response, so
    // which one woke us has to be distinguished before trusting the buffer.
    if dropped { throw TransferError.linkDropped("control response for \(what)") }
    guard let response else {
      throw TransferError.timedOut("control response was not decodable")
    }
    guard response.succeeded else {
      throw TransferError.ringReportedFailure(status: response.status,
                                              address: request.address)
    }
    // A write's byteCount reports what the ring accepted, not what it is about to
    // send; only a read streams a payload back.
    guard request.operation.expectsDataPayload, response.byteCount > 0 else {
      return (response, [])
    }

    // The data channel carries no framing; the announced count is what says when
    // the payload is complete.
    let deadline = Date().addingTimeInterval(Self.responseTimeout)
    while Date() < deadline {
      lock.lock()
      let received = dataBuffer.count
      let lost = linkGeneration != generation
      lock.unlock()
      if lost { throw TransferError.linkDropped("payload for \(what)") }
      if received >= Int(response.byteCount) { break }
      Thread.sleep(forTimeInterval: 0.02)
    }

    lock.lock()
    let bytes = dataBuffer
    lock.unlock()
    guard bytes.count >= Int(response.byteCount) else {
      throw TransferError.shortTransfer(expected: response.byteCount, received: bytes.count)
    }
    return (response, Array(bytes.prefix(Int(response.byteCount))))
  }

  private func deliver(_ response: TelestoResponse) {
    lock.lock()
    pendingResponse = response
    lock.unlock()
    signal.signal()
  }

  private func appendData(_ bytes: [UInt8]) {
    lock.lock()
    dataBuffer += bytes
    lock.unlock()
  }
}
#endif
