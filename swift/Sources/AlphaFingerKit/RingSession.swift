#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// Connects to a ring, enumerates its full GATT tree, subscribes to everything
/// notifiable, and records every byte in both directions.
///
/// Discovery passes `nil` filters throughout, so undocumented services and
/// characteristics appear rather than being filtered out before we ever see them.
///
/// Read-only with respect to ring memory: the only writes are Telesto requests
/// the caller explicitly issues, and `send` refuses the mutating opcodes.
public final class RingSession: NSObject, @unchecked Sendable {
  public enum SessionError: Error, CustomStringConvertible {
    case refusedMutatingOperation(TelestoOperation)
    case characteristicNotFound(CBUUID)
    case notConnected
    case pairingFailed(String)
    case bondHeldElsewhere
    case writeTooLarge(bytes: Int, limit: Int, characteristic: CBUUID)

    public var description: String {
      switch self {
      case let .refusedMutatingOperation(operation):
        return "refusing \(operation): this build issues read-only Telesto requests only. "
          + "Memory writes are out of scope until the read path is proven."
      case let .characteristicNotFound(uuid):
        return "characteristic \(uuid.uuidString) not found on this peripheral"
      case .notConnected:
        return "not connected"
      case let .writeTooLarge(bytes, limit, characteristic):
        return "cannot write \(bytes) bytes to \(characteristic.uuidString) in one "
          + "ATT operation: the peripheral accepts at most \(limit). A Telesto "
          + "request split across two writes would be read as garbage."
      case let .pairingFailed(message):
        return "the ring refused to pair: \(message). Remove \"Pebble Index\" in "
          + "System Settings > Bluetooth if it is listed."
      case .bondHeldElsewhere:
        return "the ring is already paired with another device -- almost certainly "
          + "your phone. It keeps one bond, and will not start a second pairing "
          + "until that one is removed. Unpair it there and it will connect here."
      }
    }
  }

  /// Where a connection has got to.
  ///
  /// Split out because the interesting failure is not "disconnected" but "stuck
  /// before encryption" -- the two look identical from outside and need entirely
  /// different responses from the user.
  public enum Phase: String, Sendable {
    case idle, connecting, discovering, pairing, subscribing, ready
  }

  /// The two Telesto channels.
  public static let telestoControl = CBUUID(string: "C0EF558A-2058-FABF-A140-8D5ACDE50B39")
  public static let telestoData = CBUUID(string: "DAAD3D52-237C-90A7-B54B-8854A134D801")
  public static let systemInput = CBUUID(string: "1D1F4039-23F5-33B2-C24E-704351F20585")

  /// The ring's service, in both the forms it can be advertised as.
  ///
  /// CoreBluetooth does *not* treat these as equivalent -- `CBUUID("FCC9")`
  /// expands to the Bluetooth base UUID, a different value from the custom one --
  /// so both are offered to the scanner.
  public static let serviceUUID = CBUUID(string: "FCC9")
  public static let serviceUUID128 = CBUUID(string: "607B5C9B-3700-4E94-F44A-2DF900BCB0C3")

  static func describe(_ state: CBManagerState) -> String {
    switch state {
    case .poweredOn: return "poweredOn"
    case .poweredOff: return "poweredOff"
    case .unauthorized: return "unauthorized (grant Bluetooth permission to this binary)"
    case .unsupported: return "unsupported"
    case .resetting: return "resetting"
    case .unknown: return "unknown"
    @unknown default: return "unrecognised(\(state.rawValue))"
    }
  }

  /// What to scan for.
  ///
  /// The ring advertises the **128-bit** form -- AD type `0x07` carries it. The
  /// 16-bit alias is kept as a superset because CoreBluetooth does *not* treat the
  /// two as equivalent -- `CBUUID("FCC9")` expands to the Bluetooth base UUID,
  /// which is a different value from the ring's custom one. The manufacturer-data
  /// gate in `didDiscover` makes the wider filter harmless.
  static let scanServices = [serviceUUID128, serviceUUID]

  /// Called with each 12-byte Telesto control response.
  public var onTelestoResponse: ((TelestoResponse) -> Void)?
  /// Called with each data-channel notification payload, in arrival order.
  public var onDataBytes: (([UInt8]) -> Void)?
  /// Called when the peripheral disconnects, for whatever reason.
  public var onDisconnect: (() -> Void)?

  private let capture: CaptureLog
  private let target: UUID?
  /// Subscribe every notifiable characteristic, not just the two that are needed.
  ///
  /// Off by default so the menubar app subscribes only what it uses. `alphafinger-cli
  /// probe` turns it on: the whole point of that command is to record channels we
  /// have not characterised yet, and losing that would narrow what future captures
  /// can show. Extra channels are subscribed only *after* the required two, so
  /// readiness timing is unaffected either way.
  private let subscribeEverythingNotifiable: Bool
  /// A ring seen before, tried first but never required.
  ///
  /// Deliberately separate from `target`: `target` restricts which ring we will
  /// talk to at all, so reusing it for a remembered identifier would lock the app
  /// out entirely once that identifier went stale (a removed bond can change it).
  /// This only skips the scan when it works.
  private let preferred: UUID?
  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var characteristics: [CBUUID: CBCharacteristic] = [:]
  private var pendingDiscoveries = 0
  private var lastNotification: [CBUUID: TimeInterval] = [:]
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "alphafinger.session")
  private let onReady: @Sendable (RingSession) -> Void

  /// True once both Telesto channels are subscribed and requests can be issued.
  ///
  /// Goes false the instant `hangUp` is called, not when the disconnect callback
  /// eventually arrives. `cancelPeripheralConnection` is asynchronous, so without
  /// that a caller queued behind a long transfer would see `isReady == true` and
  /// write into a link that is already closing -- which produced a "the ring
  /// dropped the link" error the ring had nothing to do with.
  public var isReady: Bool { isLinkReady && !isClosing }
  private var isLinkReady = false
  private var isClosing = false
  /// How far the current connection has got. Observed by the UI.
  public private(set) var phase: Phase = .idle
  /// Fires on every phase transition, so the menu can say what is happening
  /// rather than only "connected" or not.
  public var onPhaseChange: ((Phase) -> Void)?
  /// Fires when pairing is provably required and could not be completed.
  public var onPairingFailed: ((Error) -> Void)?
  /// Consulted before every connection. Supplying nil connects on sight, which is
  /// what `alphafinger-cli probe` wants; the menubar app supplies real history so it
  /// only connects when the ring has something to hand over.
  public var connectionHistory: (() -> ConnectionGate.History)?
  /// Fires when an advertisement was seen but deliberately not acted on.
  public var onStayedAway: ((RingAdvertisement) -> Void)?
  /// Fires on every advertisement saying the ring has nothing pending and is not
  /// recording. Deliberately **not** throttled, unlike `onStayedAway`: it is what
  /// releases a held gesture, and a minute of throttling would be a minute of
  /// delay on a tap. Cheap enough -- the handler only acts when something is held.
  public var onRingIdle: ((RingAdvertisement) -> Void)?
  /// Fires once a ring is bonded and both Telesto channels are subscribed, so the
  /// application can persist its identifier and reconnect next launch without
  /// scanning. Deliberately not fired at discovery: being seen is not being paired.
  public var onPeripheralIdentified: ((UUID) -> Void)?

  /// Set while the pairing probe write is outstanding.
  private var isProbingPairing = false
  /// Telesto channels confirmed notifying on this connection.
  private var subscribed: Set<CBUUID> = []

  /// A single zero byte written to the data channel, purely to draw an
  /// `Insufficient Authentication` error out of the ring.
  ///
  /// This is what makes pairing happen. CoreBluetooth exposes no way to ask for
  /// it; the stack starts SMP only when an ATT *request* is refused for want of
  /// authentication, and then transparently replays the request once bonded. The
  /// one `00` written to the data channel before anything else is what starts it;
  /// without this step the client loops on `Encryption is insufficient`.
  ///
  /// Subscribing does not work as the trigger: a CCCD write on an unencrypted
  /// link returns `Insufficient Encryption` (0x0F), which macOS reports as a
  /// plain error instead of pairing on it.
  static let pairingProbe: [UInt8] = [0x00]

  /// Channels that must be notifying before requests may be issued, in the order
  /// they must be subscribed.
  static let requiredChannels: [CBUUID] = [telestoControl, telestoData]

  /// Restart the scan if this long passes with no ring advertisement.
  ///
  /// A scan that has silently died is the failure
  /// that looks exactly like "no ring nearby", which is unfalsifiable from the
  /// menu, so it is simply restarted periodically.
  static let scanRestartWhenIdle: TimeInterval = 10
  /// Unconditional scan restart, dodging the OS downgrading a long-running scan.
  /// dodging the OS downgrading a long-running scan.
  static let scanRestartInterval: TimeInterval = 900
  /// How a failed pairing probe should be read. Split out from the delegate so it
  /// can be tested without a peripheral.
  public enum ProbeFailure: Equatable, Sendable {
    /// ATT 0x0F. Another central holds the bond; retrying cannot help.
    case bondHeldElsewhere
    /// Anything else, including ATT 0x05.
    case ordinaryPairingFailure
  }

  public static func classifyProbeFailure(attCode: Int?) -> ProbeFailure {
    attCode == CBATTError.insufficientEncryption.rawValue
      ? .bondHeldElsewhere : .ordinaryPairingFailure
  }

  /// How long to leave the ring alone after it refuses to pair because another
  /// device holds its bond. Nothing we do can change that until the user acts.
  public static let bondConflictBackoff: TimeInterval = 300

  /// Give up on a connection attempt after this long. About 8x the worst healthy
  /// connect observed.
  static let connectTimeout: TimeInterval = 15

  /// Outbound chunk size.
  ///
  /// 20 bytes is what the ring's firmware has actually been exercised with -- it
  /// is the payload of the 23-byte default MTU. CoreBluetooth negotiates a larger
  /// MTU and offers no way to force 23, so chunking keeps writes to that size. Telesto requests are 13 bytes, so this is a safety net, not a hot path.
  static let writeChunkBytes = 20

  private let gate = ConnectionGate()
  /// Set when the ring refused to pair because its bond belongs elsewhere.
  private var bondConflictUntil: Date?
  /// The most recent advertisement from this ring, so a caller can record the
  /// collection count it fetched against.
  public private(set) var latestAdvertisement: RingAdvertisement?
  /// When the last "nothing to do" was recorded. Advertisements arrive several
  /// times a second with duplicates enabled, so both the capture log and the UI
  /// callback are throttled -- logging every one would bury the file, and
  /// republishing UI state that often is what makes windows churn.
  private var lastStayedAwayReport = Date.distantPast
  static let stayedAwayReportInterval: TimeInterval = 60
  /// When an advertisement from a ring last arrived. Stamped before the
  /// manufacturer-data gate, so it answers "is a ring on the air", not "is one
  /// worth connecting to".
  ///
  /// Written in exactly one place -- `didDiscover`. It previously doubled as the
  /// scan watchdog's seed, which meant starting a scan refreshed it; since the
  /// watchdog restarts the scan every ten seconds, the value was never stale and
  /// anything derived from it was true from launch whether or not a ring existed.
  /// The watchdog now has its own clock below.
  public private(set) var lastAdvertisementDate = Date.distantPast

  /// When the current scan began. The idle watchdog measures from here, so a scan
  /// that has just started is not immediately restarted.
  private var scanStartedAt = Date.distantPast
  private var scanIdleTimer: DispatchSourceTimer?
  private var connectTimer: DispatchSourceTimer?
  private var scanRestartTimer: DispatchSourceTimer?
  /// Chunks waiting for the peripheral to be ready for write-without-response.
  private var outbound: [(characteristic: CBCharacteristic, bytes: [UInt8])] = []
  /// Set once the caller asks to stop, so a deliberate disconnect is not treated
  /// as a dropped link and immediately reconnected.
  private var isStopping = false

  /// `target` nil means "connect to the first ring seen". `preferred` is a
  /// previously-seen ring to try before scanning; it is a shortcut, not a filter.
  public init(capture: CaptureLog, target: UUID?, preferred: UUID? = nil,
              subscribeEverythingNotifiable: Bool = false,
              onReady: @escaping @Sendable (RingSession) -> Void) {
    self.capture = capture
    self.target = target
    self.preferred = preferred
    self.subscribeEverythingNotifiable = subscribeEverythingNotifiable
    self.onReady = onReady
    super.init()
    central = CBCentralManager(delegate: self, queue: queue)
  }

  /// Issues a Telesto request on the control channel, with an optional payload
  /// sent on the data channel.
  ///
  /// Mutating opcodes are refused rather than gated behind a flag: a stray write
  /// to a ring's stored data is not recoverable by re-running the tool. The one
  /// exception is setting the ring's **clock**, which writes no stored data and
  /// is required for recordings to carry the right time.
  public func send(_ request: TelestoRequest, payload: [UInt8] = []) throws {
    switch request.operation {
    case .eraseMemory:
      // The ring tolerates exactly one erase at 0x40030000, length 2, on the
      // first connection after bonding. This client never sends it. 0x40030000 is
      // the register block base so it is probably not a data erase, but
      // "probably" is not good enough to send an erase to a device whose
      // recordings cannot be recovered.
      throw SessionError.refusedMutatingOperation(request.operation)
    case .programMemory where request.address != TelestoAddress.ringClock:
      throw SessionError.refusedMutatingOperation(request.operation)
    case .programMemory, .noOperation, .readMemory, .cancelOperation:
      break
    }
    // `enqueue` looks the peripheral up itself; this only checks we have one.
    guard peripheral != nil else { throw SessionError.notConnected }
    guard let characteristic = characteristics[Self.telestoControl] else {
      throw SessionError.characteristicNotFound(Self.telestoControl)
    }

    let bytes = request.encoded()
    capture.append("write", [
      "characteristic": Self.telestoControl.uuidString,
      "payload": capture.payload(bytes, label: "telesto-request"),
      "decoded": [
        "operation": String(describing: request.operation),
        "address": String(format: "0x%08X", request.address),
        "offset": Int(request.offset),
        "length": Int(request.length),
      ],
    ])
    try enqueue(bytes, to: characteristic, atomic: true)

    if !payload.isEmpty {
      guard let dataChannel = characteristics[Self.telestoData] else {
        throw SessionError.characteristicNotFound(Self.telestoData)
      }
      capture.append("write", [
        "characteristic": Self.telestoData.uuidString,
        "payload": capture.payload(payload, label: "telesto-payload"),
      ])
      try enqueue(payload, to: dataChannel)
    }
  }

  /// Drops the link and reconnects, which runs the pairing probe again.
  ///
  /// This is what a "pair" button has to do. CoreBluetooth offers no call that
  /// means "bond with this peripheral" -- bonding is a side effect of an ATT
  /// request the ring refuses -- so retrying pairing means retrying the
  /// connection.
  public func reconnect() {
    capture.append("reconnect", ["note": "retrying pairing at the user's request"])
    lock.lock()
    subscribed.removeAll()
    isProbingPairing = false
    outbound.removeAll()
    lock.unlock()
    isLinkReady = false
    if let peripheral {
      // The disconnect handler reconnects, because isStopping stays false, and
      // the probe runs again on the new connection.
      central.cancelPeripheralConnection(peripheral)
      return
    }
    setPhase(.idle)
    beginConnecting()
  }

  /// Connects to the ring, scanning only if we have not already found it.
  ///
  /// A peripheral already in hand is connected to directly: `connect()` is a
  /// standing request that CoreBluetooth keeps pending until the ring is in
  /// range, which reconnects in milliseconds instead of paying for a fresh scan
  /// every time the ring drops the link.
  private func beginConnecting() {
    if let peripheral {
      setPhase(.connecting)
      armConnectTimeout(for: peripheral)
      central.connect(peripheral)
      return
    }
    if let wanted = preferred ?? target,
       let known = central.retrievePeripherals(withIdentifiers: [wanted]).first {
      capture.append("retrievedKnownPeripheral",
                     ["peripheral": known.identifier.uuidString])
      peripheral = known
      known.delegate = self
      setPhase(.connecting)
      armConnectTimeout(for: known)
      central.connect(known)
      return
    }
    startScanning()
  }

  private func startScanning() {
    guard central.state == .poweredOn else { return }
    capture.append("scanStarted",
                   ["service": Self.scanServices.map { $0.uuidString }])
    lock.lock(); scanStartedAt = Date(); lock.unlock()
    central.scanForPeripherals(
      withServices: Self.scanServices,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    armScanSupervision()
  }

  /// Two watchdogs: restart if nothing is seen for a
  /// while, and restart periodically regardless.
  private func armScanSupervision() {
    guard scanIdleTimer == nil else { return }
    let idle = DispatchSource.makeTimerSource(queue: queue)
    idle.schedule(deadline: .now() + Self.scanRestartWhenIdle,
                  repeating: Self.scanRestartWhenIdle)
    idle.setEventHandler { [weak self] in self?.restartScanIfIdle() }
    scanIdleTimer = idle
    idle.resume()

    let periodic = DispatchSource.makeTimerSource(queue: queue)
    periodic.schedule(deadline: .now() + Self.scanRestartInterval,
                      repeating: Self.scanRestartInterval)
    periodic.setEventHandler { [weak self] in
      guard let self, self.peripheral == nil else { return }
      self.capture.append("scanRestart", ["reason": "periodic"])
      self.central.stopScan()
      self.startScanning()
    }
    scanRestartTimer = periodic
    periodic.resume()
  }

  private func restartScanIfIdle() {
    guard peripheral == nil else { return }
    // Measured from the later of "a ring was heard" and "this scan began", so a
    // fresh scan gets its full window before being restarted.
    lock.lock()
    let last = max(lastAdvertisementDate, scanStartedAt)
    lock.unlock()
    guard Date().timeIntervalSince(last) >= Self.scanRestartWhenIdle else { return }
    // Report the advertisement clock, not the watchdog's own, so the log says how
    // long the ring has actually been silent rather than how long this scan has
    // been running.
    let heard = lastAdvertisementDate == .distantPast
      ? "never" : "\(Int(Date().timeIntervalSince(lastAdvertisementDate)))s ago"
    capture.append("scanRestart", [
      "reason": "no ring advertisement",
      "lastHeard": heard,
      "scanAgeSeconds": Int(Date().timeIntervalSince(last)),
    ])
    central.stopScan()
    startScanning()
  }

  /// Cancels a connection attempt that never completes, so the gate can retry.
  ///
  /// CoreBluetooth's `connect()` never times out on its own -- it stays pending
  /// indefinitely. One attempt was observed taking 59 s while every healthy
  /// connect that day took 0.5-1.9 s, and the app had no way to notice: it simply
  /// sat in `.connecting`.
  private func armConnectTimeout(for peripheral: CBPeripheral) {
    connectTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.connectTimeout)
    timer.setEventHandler { [weak self] in
      guard let self, !self.isReady else { return }
      self.capture.append("connectTimedOut", [
        "peripheral": peripheral.identifier.uuidString,
        "afterSeconds": Int(Self.connectTimeout),
      ])
      self.central.cancelPeripheralConnection(peripheral)
    }
    connectTimer = timer
    timer.resume()
  }

  private func cancelScanSupervision() {
    scanIdleTimer?.cancel(); scanIdleTimer = nil
    scanRestartTimer?.cancel(); scanRestartTimer = nil
  }

  /// Writes queued chunks while the peripheral will accept them.
  ///
  /// Write-without-response has no completion callback and CoreBluetooth
  /// **silently discards** a write issued while `canSendWriteWithoutResponse` is
  /// false. A dropped Telesto request looks exactly like a ring that did not
  /// answer, so the queue is not optional.
  private func drainOutbound() {
    guard let peripheral else { return }
    while peripheral.canSendWriteWithoutResponse {
      lock.lock()
      let next = outbound.isEmpty ? nil : outbound.removeFirst()
      let remaining = outbound.count
      lock.unlock()
      guard let next else { return }
      peripheral.writeValue(Data(next.bytes), for: next.characteristic,
                            type: .withoutResponse)
      capture.append("writeSent", [
        "characteristic": next.characteristic.uuid.uuidString,
        "bytes": next.bytes.count,
        "queued": remaining,
      ])
    }
  }

  /// Queues bytes for the peripheral, splitting them if `atomic` is false.
  ///
  /// A Telesto control frame is 13 bytes and must arrive as **one** write — the
  /// ring reads a whole request or nothing — so `atomic` callers throw rather than
  /// silently splitting into two writes the ring would read as garbage.
  private func enqueue(_ bytes: [UInt8], to characteristic: CBCharacteristic,
                       atomic: Bool = false) throws {
    let limit = min(Self.writeChunkBytes,
                    peripheral?.maximumWriteValueLength(for: .withoutResponse)
                      ?? Self.writeChunkBytes)
    guard limit > 0 else {
      throw SessionError.writeTooLarge(bytes: bytes.count, limit: limit,
                                       characteristic: characteristic.uuid)
    }
    if atomic, bytes.count > limit {
      throw SessionError.writeTooLarge(bytes: bytes.count, limit: limit,
                                       characteristic: characteristic.uuid)
    }
    lock.lock()
    for start in stride(from: 0, to: bytes.count, by: limit) {
      outbound.append((characteristic, Array(bytes[start ..< min(start + limit,
                                                                 bytes.count)])))
    }
    lock.unlock()
    drainOutbound()
  }

  public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    drainOutbound()
  }

  /// Drops the link but keeps looking, for when a fetch is finished and holding
  /// the connection open would only cost the ring radio time.
  public func hangUp() {
    guard let peripheral else { return }
    // Set before cancelling, so anything already queued declines rather than
    // writing to a link that is on its way out.
    isClosing = true
    capture.append("hangUp", ["note": "batch complete; releasing the link"])
    central.cancelPeripheralConnection(peripheral)
  }

  /// Whether the link is closing at our own request, so a failure raised now is
  /// self-inflicted rather than the ring's doing.
  public var isClosingDeliberately: Bool { isClosing }

  public func disconnect() {
    isStopping = true
    cancelScanSupervision()
    if let peripheral { central.cancelPeripheralConnection(peripheral) }
  }
}

extension RingSession: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    capture.append("state", ["state": Self.describe(central.state)])
    guard central.state == .poweredOn else { return }
    beginConnecting()
  }

  public func centralManager(_ central: CBCentralManager,
                             didDiscover peripheral: CBPeripheral,
                             advertisementData: [String: Any],
                             rssi RSSI: NSNumber) {
    if let target, peripheral.identifier != target { return }
    guard self.peripheral == nil else { return }
    lock.lock(); lastAdvertisementDate = Date(); lock.unlock()

    // Gating on manufacturer data after the service-UUID filter means a device
    // advertising this service that is not a ring never gets connected to.
    let manufacturerData = (advertisementData[CBAdvertisementDataManufacturerDataKey]
                            as? Data).map { [UInt8]($0) }
    guard let manufacturerData,
          RingAdvertisement.hasRingCompanyIdentifier(manufacturerData) else {
      // Logged rather than dropped: an advertiser on the ring's service whose
      // manufacturer data we cannot recognise is a finding, not noise.
      capture.append("rejectedAdvertiser", [
        "peripheral": peripheral.identifier.uuidString,
        "name": peripheral.name ?? "",
        "manufacturerData": manufacturerData.map { capture.payload($0, label: "mfg") }
          ?? "absent",
        "reason": "no Core Devices company identifier "
          + String(format: "0x%04X", RingAdvertisement.companyIdentifier),
      ])
      return
    }

    // Deciding here, from the advertisement, is what stops the busy loop: the ring
    // drops an idle link after ~10 s and we used to ask straight back, holding the
    // radio open ~90% of the time instead of around 32%.
    if let until = bondConflictUntil, Date() < until {
      return
    }
    if let history = connectionHistory?() {
      let advertisement = try? RingAdvertisement(manufacturerData: manufacturerData)
      latestAdvertisement = advertisement
      if let advertisement {
        let decision = gate.decide(advertisement: advertisement, history: history)
        guard case let .connect(reason) = decision else {
          let now = Date()
          // Nothing left to hand over and not mid-recording: whatever is holding
          // a gesture back can stop waiting.
          if !advertisement.needsServicing && !advertisement.inCollectionState {
            onRingIdle?(advertisement)
          }
          if now.timeIntervalSince(lastStayedAwayReport)
              >= Self.stayedAwayReportInterval {
            lastStayedAwayReport = now
            capture.append("stayedAway", [
              "peripheral": peripheral.identifier.uuidString,
              "collectionCount": Int(advertisement.rawCollectionCount),
              "needsServicing": advertisement.needsServicing,
              // Recorded because whether this bit ever clears while idle is what
              // decides if a held gesture is released promptly or by the backstop.
              "inCollectionState": advertisement.inCollectionState,
              "isMoving": advertisement.isMoving,
              "note": "nothing to fetch; leaving the ring alone",
            ])
            onStayedAway?(advertisement)
          }
          return
        }
        lastStayedAwayReport = .distantPast
        capture.append("connectBecause", ["reason": reason])
      }
    }

    central.stopScan()
    cancelScanSupervision()
    self.peripheral = peripheral
    peripheral.delegate = self
    capture.append("connecting", [
      "peripheral": peripheral.identifier.uuidString,
      "name": peripheral.name ?? "",
      "rssi": RSSI.intValue,
      "advertisementData": JSONSafe.dictionary(advertisementData),
    ])
    setPhase(.connecting)
    armConnectTimeout(for: peripheral)
    central.connect(peripheral)
  }

  public func centralManager(_ central: CBCentralManager,
                             didConnect peripheral: CBPeripheral) {
    // Both write types: the maxima differ, and together they pin down the
    // negotiated ATT MTU. CoreBluetooth negotiates it for us and offers no way to
    // ask for a specific value, so this is an observation rather than a setting.
    capture.append("connected", [
      "peripheral": peripheral.identifier.uuidString,
      "maximumWriteWithResponse": peripheral.maximumWriteValueLength(for: .withResponse),
      "maximumWriteWithoutResponse":
        peripheral.maximumWriteValueLength(for: .withoutResponse),
    ])
    setPhase(.discovering)
    // nil: discover everything, including services we do not know about.
    peripheral.discoverServices(nil)
  }

  public func centralManager(_ central: CBCentralManager,
                             didFailToConnect peripheral: CBPeripheral,
                             error: Error?) {
    capture.append("error", ["phase": "connect",
                             "message": String(describing: error)])
  }

  public func centralManager(_ central: CBCentralManager,
                             didDisconnectPeripheral peripheral: CBPeripheral,
                             error: Error?) {
    capture.append("disconnect", [
      "peripheral": peripheral.identifier.uuidString,
      "error": error.map { String(describing: $0) } ?? "",
      "willReconnect": !isStopping,
    ])
    isLinkReady = false
    lock.lock()
    characteristics.removeAll()
    subscribed.removeAll()
    isProbingPairing = false
    // Anything still queued belongs to the connection that just died; replaying it
    // on the next one would interleave with a fresh request.
    outbound.removeAll()
    lock.unlock()
    setPhase(.idle)
    onDisconnect?()

    guard !isStopping, central.state == .poweredOn else { return }
    // Back to scanning rather than straight back into connect(). Re-arming the
    // connection unconditionally is what made this a busy loop; the advertisement
    // decides whether the next one is worth making. When it is, `connect()` is
    // still a standing request and still completes in milliseconds.
    self.peripheral = nil
    startScanning()
  }
}

extension RingSession: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      capture.append("error", ["phase": "discoverServices",
                               "message": String(describing: error)])
      return
    }
    let services = peripheral.services ?? []
    capture.append("services", ["uuids": services.map(\.uuid.uuidString)])
    lock.lock(); pendingDiscoveries = services.count; lock.unlock()
    for service in services {
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }

  public func peripheral(_ peripheral: CBPeripheral,
                         didDiscoverCharacteristicsFor service: CBService,
                         error: Error?) {
    if let error {
      capture.append("error", ["phase": "discoverCharacteristics",
                               "service": service.uuid.uuidString,
                               "message": String(describing: error)])
    }
    for characteristic in service.characteristics ?? [] {
      lock.lock(); characteristics[characteristic.uuid] = characteristic; lock.unlock()
      capture.append("characteristic", [
        "service": service.uuid.uuidString,
        "uuid": characteristic.uuid.uuidString,
        "properties": Self.describe(characteristic.properties),
      ])
      peripheral.discoverDescriptors(for: characteristic)
    }

    lock.lock()
    pendingDiscoveries -= 1
    let finished = pendingDiscoveries <= 0
    lock.unlock()
    guard finished else { return }
    capture.append("enumerationComplete", [
      "characteristicCount": characteristics.count,
      "hasTelestoControl": characteristics[Self.telestoControl] != nil,
      "hasTelestoData": characteristics[Self.telestoData] != nil,
      "hasSystemInput": characteristics[Self.systemInput] != nil,
    ])
    probePairing(on: peripheral)
  }

  /// Provokes bonding, then subscribes.
  ///
  /// Ordering is the whole point. Subscribing first is what the earlier build
  /// did, and it cannot work: the ring answers a CCCD write on an unencrypted
  /// link with 0x0F and hangs up about a second later.
  private func probePairing(on peripheral: CBPeripheral) {
    guard let dataChannel = characteristics[Self.telestoData] else {
      capture.append("error", ["phase": "pairing",
                               "message": "no Telesto data channel to probe"])
      return
    }
    setPhase(.pairing)
    lock.lock(); isProbingPairing = true; lock.unlock()
    capture.append("pairingProbe", [
      "characteristic": Self.telestoData.uuidString,
      "payload": capture.payload(Self.pairingProbe, label: "pairing-probe"),
      "note": "one zero byte, written to draw Insufficient Authentication and "
        + "make CoreBluetooth start SMP",
    ])
    peripheral.writeValue(Data(Self.pairingProbe), for: dataChannel, type: .withResponse)
  }

  /// Subscribes the Telesto channels, control first, one at a time.
  ///
  /// Order is not cosmetic: control is subscribed before data. The
  /// previous implementation iterated a dictionary's values, so the order was
  /// whatever the hash gave us that run.
  ///
  /// systemInput is deliberately left unsubscribed -- nothing here reads it, and
  /// `alphafinger-cli probe` remains the tool for looking at other channels.
  private func subscribeNextChannel(on peripheral: CBPeripheral) {
    setPhase(.subscribing)
    lock.lock()
    let next = Self.requiredChannels.first { !subscribed.contains($0) }
    lock.unlock()
    guard let next, let characteristic = characteristics[next] else { return }
    capture.append("subscribing", ["characteristic": next.uuidString])
    peripheral.setNotifyValue(true, for: characteristic)
  }

  private func setPhase(_ new: Phase) {
    guard phase != new else { return }
    phase = new
    capture.append("phase", ["phase": new.rawValue])
    onPhaseChange?(new)
  }

  public func peripheral(_ peripheral: CBPeripheral,
                         didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                         error: Error?) {
    for descriptor in characteristic.descriptors ?? [] {
      capture.append("descriptor", [
        "characteristic": characteristic.uuid.uuidString,
        "uuid": descriptor.uuid.uuidString,
      ])
    }
  }

  public func peripheral(_ peripheral: CBPeripheral,
                         didUpdateNotificationStateFor characteristic: CBCharacteristic,
                         error: Error?) {
    capture.append("subscribe", [
      "characteristic": characteristic.uuid.uuidString,
      "isNotifying": characteristic.isNotifying,
      "error": error.map { String(describing: $0) } ?? "",
    ])
    guard error == nil, characteristic.isNotifying else { return }

    lock.lock()
    subscribed.insert(characteristic.uuid)
    let ready = Self.requiredChannels.allSatisfy(subscribed.contains)
    let alreadyReady = isLinkReady
    if ready { isLinkReady = true }
    lock.unlock()

    guard ready else {
      subscribeNextChannel(on: peripheral)
      return
    }
    // Only now can a request be answered: the response arrives as a notification,
    // so issuing one before this point loses the reply.
    guard !alreadyReady else { return }
    connectTimer?.cancel()
    connectTimer = nil
    isClosing = false
    // Only now is the ring genuinely ours: bonded, and both Telesto channels
    // notifying. Reporting it at discovery meant merely *seeing* the ring marked
    // it as known, so after a run of failed pairings the app offered to unpair a
    // ring it had never paired with.
    bondConflictUntil = nil
    onPeripheralIdentified?(peripheral.identifier)
    subscribeRemainingIfRequested(on: peripheral)
    setPhase(.ready)
    onReady(self)
  }

  private func subscribeRemainingIfRequested(on peripheral: CBPeripheral) {
    guard subscribeEverythingNotifiable else { return }
    lock.lock(); let done = subscribed; let all = characteristics; lock.unlock()
    for (uuid, characteristic) in all where !done.contains(uuid) {
      guard characteristic.properties.contains(.notify)
        || characteristic.properties.contains(.indicate) else { continue }
      capture.append("subscribing", ["characteristic": uuid.uuidString,
                                     "note": "beyond the two Telesto channels"])
      peripheral.setNotifyValue(true, for: characteristic)
    }
  }

  public func peripheral(_ peripheral: CBPeripheral,
                         didUpdateValueFor characteristic: CBCharacteristic,
                         error: Error?) {
    if let error {
      capture.append("error", ["phase": "notification",
                               "characteristic": characteristic.uuid.uuidString,
                               "message": String(describing: error)])
      return
    }
    let bytes = [UInt8](characteristic.value ?? Data())

    // Inter-frame timing distinguishes a response from an unsolicited push, and
    // reveals chunking -- both needed to reverse the response framing.
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    let previous = lastNotification[characteristic.uuid]
    lastNotification[characteristic.uuid] = now
    lock.unlock()

    var event: [String: Any] = [
      "characteristic": characteristic.uuid.uuidString,
      "payload": capture.payload(bytes, label: "notify"),
    ]
    if let previous { event["deltaMsSincePreviousOnCharacteristic"] = (now - previous) * 1000 }
    // The unknown 12-byte control frame is the thing this whole phase exists to
    // capture; flag it so it is trivial to grep out of a long session.
    if characteristic.uuid == Self.telestoControl {
      event["isTelestoControlFrame"] = true
      event["matchesExpectedControlFrameLength"] =
        bytes.count == TelestoControlResponse.frameLength
      if let response = TelestoResponse(bytes: bytes) {
        event["decoded"] = ["status": Int(response.status),
                            "byteCount": Int(response.byteCount)]
        onTelestoResponse?(response)
      }
    } else if characteristic.uuid == Self.telestoData {
      onDataBytes?(bytes)
    }
    capture.append("notification", event)
  }

  public func peripheral(_ peripheral: CBPeripheral,
                         didWriteValueFor characteristic: CBCharacteristic,
                         error: Error?) {
    capture.append("writeComplete", [
      "characteristic": characteristic.uuid.uuidString,
      "error": error.map { String(describing: $0) } ?? "",
    ])

    lock.lock()
    let wasProbe = isProbingPairing && characteristic.uuid == Self.telestoData
    if wasProbe { isProbingPairing = false }
    lock.unlock()
    guard wasProbe else { return }

    // Reaching here without an error means the link is encrypted: CoreBluetooth
    // pairs on the ring's Insufficient Authentication and replays the write, so
    // success is reported only once bonded. An error means pairing did not
    // happen, and no amount of retrying the subscribe will help.
    if let error {
      // 0x0F Insufficient Encryption, not 0x05 Insufficient Authentication. The
      // this write draws 0x05 on an unbonded link, which is what makes
      // CoreBluetooth start SMP. 0x0F instead means the ring will not pair at all
      // right now -- observed 8 times out of 8 while a phone held the bond -- and
      // macOS does not pair on it. Retrying cannot change the answer, so it is
      // classified separately and backed off.
      let nsError = error as NSError
      let attCode = nsError.domain == CBATTErrorDomain ? nsError.code : nil
      if Self.classifyProbeFailure(attCode: attCode) == .bondHeldElsewhere {
        capture.append("bondHeldElsewhere", [
          "message": String(describing: error),
          "note": "another central holds the ring's bond; not retrying for "
            + "\(Int(Self.bondConflictBackoff))s",
        ])
        bondConflictUntil = Date().addingTimeInterval(Self.bondConflictBackoff)
        setPhase(.idle)
        onPairingFailed?(SessionError.bondHeldElsewhere)
        return
      }
      capture.append("pairingFailed", ["message": String(describing: error)])
      setPhase(.idle)
      onPairingFailed?(SessionError.pairingFailed(String(describing: error)))
      return
    }
    capture.append("paired", ["note": "link encrypted; subscribing"])
    lock.lock(); subscribed.removeAll(); lock.unlock()
    subscribeNextChannel(on: peripheral)
  }

  static func describe(_ properties: CBCharacteristicProperties) -> [String] {
    var names: [String] = []
    let table: [(CBCharacteristicProperties, String)] = [
      (.broadcast, "broadcast"), (.read, "read"),
      (.writeWithoutResponse, "writeWithoutResponse"), (.write, "write"),
      (.notify, "notify"), (.indicate, "indicate"),
      (.authenticatedSignedWrites, "authenticatedSignedWrites"),
      (.extendedProperties, "extendedProperties"),
      (.notifyEncryptionRequired, "notifyEncryptionRequired"),
      (.indicateEncryptionRequired, "indicateEncryptionRequired"),
    ]
    for (flag, name) in table where properties.contains(flag) {
      names.append(name)
    }
    return names
  }
}
#endif
