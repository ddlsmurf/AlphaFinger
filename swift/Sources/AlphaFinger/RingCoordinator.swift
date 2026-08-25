import Combine
import Foundation
import AlphaFingerKit
import SwiftUI

/// One line in the debug window.
struct DebugEntry: Identifiable {
  let id = UUID()
  let time: Date
  let kind: String
  let detail: String
}

/// Owns the source, the pipeline and the log; publishes what the UI shows.
@MainActor
final class RingCoordinator: ObservableObject {
  @Published private(set) var isConnected = false
  @Published private(set) var isRunning = false
  /// How far the current connection attempt has got.
  @Published private(set) var phase: RingSession.Phase = .idle
  /// Set when the ring would not bond; cleared by a successful pairing.
  @Published private(set) var pairingProblem: String?
  /// When the "another device holds my bond" complaint stops being current.
  ///
  /// Time-boxed rather than a sticky flag. The session backs off for the same
  /// window, so once it lapses we genuinely do not know the state any more and
  /// saying "your phone is using the ring" would be a stale assertion.
  @Published private(set) var bondConflictUntil: Date?
  private var bondConflictTimer: Timer?

  var bondConflict: Bool {
    guard let until = bondConflictUntil else { return false }
    return Date() < until
  }
  @Published private(set) var lastFiled: String?
  @Published private(set) var recordingCount = 0
  @Published private(set) var gestureCount = 0
  /// Collections the ring discarded before the app fetched them.
  @Published private(set) var missedCollections: UInt32 = 0
  /// How many times the ring has restarted its collection numbering.
  @Published private(set) var ringResetCount = 0
  /// True while collections are being pulled off the ring.
  @Published private(set) var isDownloading = false
  /// Derived rather than stored; the rule and its window live in `RingPresence`
  /// so they are testable.
  var isIdleNearby: Bool {
    RingPresence.isNearby(lastHeard: live?.lastAdvertisementDate)
  }
  /// True after an unpair, until a ring is adopted again. Drives the reminder
  /// that the Bluetooth bond itself still has to be removed by hand.
  @Published private(set) var awaitingBluetoothRemoval = false
  /// Consecutive failed fetch cycles. Any success clears it.
  @Published private(set) var consecutiveFailures = 0
  @Published private(set) var entries: [DebugEntry] = []
  @Published private(set) var captureDirectory: URL?

  /// Keeps memory bounded during a long session; the JSONL on disk is complete.
  static let maximumEntries = 2000

  /// Failures in a row before the menubar icon says so.
  ///
  /// More than one, because the ring dropping a link mid-fetch is routine and the
  /// next cycle usually just works -- an icon that flickered on every drop would
  /// mean nothing.
  static let failuresBeforeAlarm = 3

  /// The app's state as a user experiences it.
  ///
  /// Coarser than `RingSession.Phase`: pairing and subscribing are transport steps
  /// that pass in milliseconds and mean nothing to someone waiting for a
  /// recording. The icons form one family and read as a progression -- dashes for
  /// nothing, dots for looking, a filled ring for connected.
  enum Status {
    /// No ring has ever been paired, or the last one was unpaired.
    case noRing
    /// Paired, but no advertisement lately -- charging, out of range, or with the
    /// phone.
    case searching
    /// Seen, and working through connecting, pairing and subscribing.
    case connecting
    /// Ring nearby with nothing to hand over. The healthy resting state, and it
    /// has to say so: an app that does nothing for hours is otherwise
    /// indistinguishable from one that has hung.
    case idleNearby
    /// Connected, nothing in flight.
    case ready
    /// Pulling a recording off the ring.
    case downloading
    /// The ring is paired to another device -- practically always the phone --
    /// and keeps one bond. Retrying cannot help; the user has to act.
    case bondHeldElsewhere
    /// Repeated failure, or a ring that will not pair. Needs a human.
    case attention

    /// How the ring is drawn for this state. The band carries the state; the
    /// button never changes, so the glyph stays the same object throughout.
    var glyph: (band: RingGlyph.Band, mark: RingGlyph.Mark) {
      switch self {
      case .noRing: return (.dashed, .none)
      case .searching: return (.dotted, .none)
      case .connecting: return (.dotted, .dot)
      case .idleNearby: return (.solid, .none)
      case .ready: return (.solid, .filled)
      case .downloading: return (.solid, .downArrow)
      case .bondHeldElsewhere: return (.solid, .slash)
      case .attention: return (.solid, .exclamation)
      }
    }

    var summary: String {
      switch self {
      case .noRing: return "No ring yet — wear it and press the button"
      case .searching: return "Waiting for your ring"
      case .connecting: return "Connecting…"
      case .idleNearby: return "Ring nearby — nothing to collect"
      case .ready: return "Ring connected"
      case .downloading: return "Downloading…"
      case .bondHeldElsewhere: return "Your phone is using the ring"
      case .attention: return "Can't reach the ring"
      }
    }
  }

  var status: Status {
    // Anything actually happening outranks a stale complaint.
    if isDownloading { return .downloading }
    if isConnected { return phase == .ready ? .ready : .connecting }
    if bondConflict { return .bondHeldElsewhere }
    if pairingProblem != nil { return .attention }
    if consecutiveFailures >= Self.failuresBeforeAlarm { return .attention }
    if !hasKnownRing { return .noRing }
    return isIdleNearby ? .idleNearby : .searching
  }

  /// The ring's battery as of the last fetch, and when that was.
  ///
  /// Battery rides in collections, not in the advertisement, and this client never
  /// connects just to look -- so the age is shown alongside and can legitimately
  /// be days. Millivolts, not a percentage: 1560-1579 mV is the whole observed
  /// range and there is no documented full/empty, so a percentage would be a guess
  /// presented as a fact.
  @Published private(set) var batteryMilliVolts: UInt16?
  @Published private(set) var batteryReadAt: Date?

  /// Past this the reading says nothing useful about the ring's present state,
  /// and a figure sitting beside the status line reads as current health.
  static let batteryFreshness: TimeInterval = 30 * 60

  /// `asOf` is supplied by the caller so the age advances on a clock rather than
  /// freezing at whatever it said when the menu was last built.
  func batterySummary(asOf now: Date = Date()) -> String? {
    guard let millivolts = batteryMilliVolts, let at = batteryReadAt,
          now.timeIntervalSince(at) < Self.batteryFreshness else { return nil }
    let volts = String(format: "%.2f V", Double(millivolts) / 1000)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Battery \(volts) · \(formatter.localizedString(for: at, relativeTo: now))"
  }

  private let settings: AppSettings
  private var source: RingSource?
  /// Typed separately from `source`: retrying pairing is meaningless for a replay.
  private var live: LiveRingSource?
  private var pipeline: RingPipeline?
  private var capture: CaptureLog?

  private var supportDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
    return base.appendingPathComponent("AlphaFinger", isDirectory: true)
  }

  private let notifier = Notifier()
  private var settingsObserver: AnyCancellable?
  /// Held so a ring reset can discard the fetch position. Unpairing no longer
  /// does: the position is tagged with its ring, so re-pairing the same one
  /// resumes and any other starts clean.
  private var cursor: DefaultsCollectionCursor?

  init(settings: AppSettings) {
    self.settings = settings
    notifier.onLog = { [weak self] message in
      self?.note("notify", message)
    }
    // The app has no Start button: it runs whenever it can. A ring that is out of
    // range or on its charger is an ordinary state, not something a user should
    // have to restart from.
    //
    // objectWillChange fires *before* the value lands, so the check is deferred a
    // turn -- otherwise isConfigured still reads the previous value.
    settingsObserver = settings.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in
        self?.startIfPossible()
        self?.applySettings()
      }
    }
    Task { @MainActor in self.startIfPossible() }
  }

  /// Hands edited settings to the pipeline that is already running.
  ///
  /// The pipeline is built from a snapshot taken at `start()`, and
  /// `startIfPossible` declines once it is running -- so without this, a command
  /// typed into Settings never reaches the pipeline at all, and the app has to be
  /// relaunched before it fires. It failed silently: nothing in the log said the
  /// pipeline was still holding an empty command.
  private func applySettings() {
    guard let pipeline, let updated = settings.pipelineSettings,
          updated != pipeline.settings else { return }
    pipeline.settings = updated
    note("settings", "applied edited settings to the running pipeline")
  }

  /// Carries a position across from the file this used to be kept in.
  ///
  /// Attributed to the known ring, because a position with no ring cannot be used
  /// safely -- and an unattributable one is discarded rather than guessed, since
  /// guessing is precisely the silent-skip failure `adopt` exists to prevent. The
  /// file is removed either way, so a stale value cannot come back.
  private func migrateCursorFile(into cursor: DefaultsCollectionCursor) {
    let fileURL = supportDirectory.appendingPathComponent("cursor.txt")
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    defer { try? FileManager.default.removeItem(at: fileURL) }

    guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
          let index = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return note("cursor", "ignored an unreadable cursor.txt") }
    guard let ring = settings.knownRingIdentifier else {
      return note("cursor", "discarded cursor.txt (position \(index)): no ring is "
                  + "known, so it cannot be attributed to one")
    }
    if cursor.seed(index: index, ring: ring) {
      note("cursor", "carried position \(index) over from cursor.txt, "
           + "attributed to ring \(ring.uuidString)")
    }
  }

  /// Starts if it is not already running and a folder has been chosen.
  ///
  /// Safe to call repeatedly -- the app calls it on launch and whenever settings
  /// change, rather than making the user press anything.
  func startIfPossible() {
    guard !isRunning, settings.isConfigured else { return }
    start()
  }

  func start() {
    guard !isRunning, let pipelineSettings = settings.pipelineSettings else {
      note("idle", "choose a folder in Settings before starting")
      return
    }
    do {
      let capture = try CaptureLog(command: "menu", arguments: [], root: supportDirectory)
      self.capture = capture
      captureDirectory = capture.directory

      let cursor = DefaultsCollectionCursor()
      migrateCursorFile(into: cursor)
      self.cursor = cursor
      let pipeline = RingPipeline(settings: pipelineSettings, cursor: cursor)
      pipeline.onOutcome = { [weak self] outcome in
        Task { @MainActor in self?.handle(outcome) }
      }
      self.pipeline = pipeline

      let live = LiveRingSource(capture: capture, cursor: cursor,
                                pollInterval: settings.pollSeconds,
                                knownRing: settings.knownRingIdentifier)
      live.onCollection = { [weak self] collection in
        Task { @MainActor in
          self?.note("collection", "index \(collection.index), "
                     + "\(collection.bytes.count) bytes, "
                     + "\(counted(collection.records.count, "record"))", level: .verbose)
          self?.isDownloading = true
          // Deliberately no flush here. A recording spans many collections and
          // the ring drops the link every few seconds; closing runs per collection
          // is what split one recording into overwriting fragments.
          self?.pipeline?.accept(collection)
        }
      }
      live.onError = { [weak self] error in
        Task { @MainActor in
          guard let self else { return }
          self.consecutiveFailures += 1
          self.note("error", "\(error) (\(self.consecutiveFailures) in a row)")
        }
      }
      live.onBatchComplete = { [weak self] in
        Task { @MainActor in
          guard let self else { return }
          // A cycle that reached the end is a working link, whatever happened
          // before it.
          self.consecutiveFailures = 0
          self.isDownloading = false
          self.pipeline?.endOfBatch()
        }
      }
      live.onCollectionsMissed = { [weak self] missed, oldest in
        Task { @MainActor in
          // Not an error the app can fix -- but the user should know recordings
          // were lost, and roughly how many.
          self?.missedCollections += missed
          self?.note("missed", "\(counted(Int(missed), "collection")) were discarded "
                     + "by the ring "
                     + "before they could be fetched; oldest still available is "
                     + "\(oldest). Poll more often, or leave the app running.")
        }
      }
      live.onConnectionChange = { [weak self] connected in
        Task { @MainActor in
          self?.isConnected = connected
          self?.note("connection", connected ? "connected" : "disconnected")
        }
      }
      live.onRingReset = { [weak self] evidence in
        Task { @MainActor in
          guard let self else { return }
          self.ringResetCount += 1
          // That count described storage the ring no longer has.
          self.missedCollections = 0
          self.pipeline?.ringDidReset(String(describing: evidence))
          self.note("ringReset", "\(evidence). Everything the ring still holds "
                    + "will be fetched again.")
        }
      }
      // Releases a gesture held back in case a recording was about to absorb it.
      // Fires several times a second, so it does nothing unless one is held.
      live.onRingIdle = { [weak self] in
        Task { @MainActor in self?.pipeline?.ringWentIdle() }
      }
      live.onCursorAdoption = { [weak self] adoption in
        Task { @MainActor in
          // Normal level, not verbose: "a different ring" means the next fetch
          // starts from the beginning, which is worth seeing without hunting.
          self?.note("cursor", adoption.description)
        }
      }
      live.onPeripheralIdentified = { [weak self] identifier in
        Task { @MainActor in
          self?.awaitingBluetoothRemoval = false
          self?.settings.knownRingIdentifier = identifier
          self?.note("ring", "identified \(identifier.uuidString)", level: .verbose)
        }
      }
      live.onBattery = { [weak self] millivolts in
        Task { @MainActor in
          self?.batteryMilliVolts = millivolts
          self?.batteryReadAt = Date()
        }
      }
      live.onIdle = { [weak self] in
        Task { @MainActor in
          self?.note("idle", "ring is nearby with nothing to collect; "
                     + "leaving it alone to save its battery", level: .verbose)
        }
      }
      live.onPhaseChange = { [weak self] phase in
        Task { @MainActor in
          // Any real connection activity means we are no longer just idling.
          if phase == .ready { self?.clearBondConflict() }
          self?.phase = phase
          if phase == .ready || phase == .subscribing { self?.pairingProblem = nil }
          self?.note("phase", phase.rawValue, level: .verbose)
        }
      }
      live.onPairingFailed = { [weak self] error in
        Task { @MainActor in
          guard let self else { return }
          if case RingSession.SessionError.bondHeldElsewhere = error {
            self.beginBondConflict()
          } else {
            self.pairingProblem = String(describing: error)
          }
          // The full text goes here; the menu shows one plain sentence.
          self.note("pairing", String(describing: error))
        }
      }
      source = live
      self.live = live
      live.start()
      isRunning = true
      note("started", "watching for a ring")
    } catch {
      note("error", "could not start: \(error)")
    }
  }

  /// Reconnects so the pairing probe runs again. See `RingSession.reconnect`.
  func retryPairing() {
    guard let live else {
      note("pairing", "not running; press Start first")
      return
    }
    pairingProblem = nil
    note("pairing", "retrying at your request")
    live.retryPairing()
  }

  func stop() {
    // Nothing more is coming, so write out any run still waiting for a final part
    // rather than discarding it with the pipeline.
    pipeline?.finish()
    source?.stop()
    source = nil
    live = nil
    phase = .idle
    capture?.close()
    capture = nil
    isRunning = false
    isConnected = false
    isDownloading = false
    clearBondConflict()
    note("stopped", "")
  }

  private func handle(_ outcome: RingOutcome) {
    switch outcome {
    case let .savedRecording(result, isDoubleTap, pattern, reason):
      recordingCount += 1
      lastFiled = result.audioURL.lastPathComponent
      if settings.notifyOnRecording {
        notifier.post(
          title: isDoubleTap ? "Tap-and-record saved" : "Recording saved",
          body: String(format: "%@ · %.1fs", result.audioURL.lastPathComponent,
                       result.durationSeconds),
          reveal: result.audioURL,
          isRoutine: true)
      }
      note("saved", "\(isDoubleTap ? "double-tap " : "")recording "
           + "\(result.audioURL.lastPathComponent), "
           + String(format: "%.2fs", result.durationSeconds)
           + ", presses \(pattern) (\(reason.rawValue))")
    case let .startedCommand(label, command, queuedSeconds):
      // At normal level: this is the line whose absence made a working command
      // look like a stalled one. The queue wait is only worth saying when there
      // was one -- it is zero unless another command was still running.
      let waited = queuedSeconds >= 0.05
        ? String(format: " (waited %.2fs in the queue)", queuedSeconds) : ""
      note("command", "\(label) started\(waited): \(command)")

    case let .ranCommand(shell, label, recording):
      // Only a gesture counts as a gesture. A post-recording command carries the
      // file it ran on, and was inflating this.
      if recording == nil { gestureCount += 1 }
      lastFiled = "\(label) command"
      note(shell.succeeded ? "command" : "error",
           String(format: "%@ exited %d after %.2fs: %@", label, shell.exitCode,
                  shell.durationSeconds, shell.command))
      // Every line of output, tagged with its stream. This is the only record of
      // why a command failed, and it is worthless collapsed onto one line.
      for output in shell.outputLines {
        note(output.stream, "\(label) | \(output.line)",
             level: shell.succeeded ? .verbose : .normal, at: output.at)
      }
      guard !shell.succeeded else { return }
      // The file first, because it is what the notification reveals when clicked
      // and what tells you which recording to look at; the last line of output is
      // the best one-line guess at why. A gesture command has no file to name.
      let failure = shell.outputLines.last?.line
        ?? "Exited with code \(shell.exitCode)."
      notifier.post(
        title: "\(label) command failed",
        body: recording.map { "\($0.lastPathComponent)\n\(failure)" } ?? failure,
        reveal: recording ?? captureDirectory,
        sound: true)
    case let .ignored(reason):
      note("ignored", reason, level: .verbose)
    case let .detail(message):
      note("detail", message, level: .verbose)
    case let .ringReset(reason):
      note("ringReset", reason)
    case let .failed(message):
      note("error", message)
    }
  }

  /// `level` is the minimum verbosity at which this appears in the window. The
  /// capture file on disk gets everything regardless.
  /// `at` is when the thing being noted actually happened, for anything that is
  /// logged after the fact. Command output is the case that matters: every line
  /// used to carry the moment the command exited, so a four-second run looked
  /// instantaneous and the order said nothing about when.
  private func note(_ kind: String, _ detail: String,
                    level: DebugVerbosity = .normal,
                    at: Date = Date()) {
    var fields: [String: Any] = ["kind": kind, "detail": detail]
    // `wall` stays "when this was written to the log"; this is when it happened.
    if Date().timeIntervalSince(at) > 0.005 {
      fields["observedAt"] = ISO8601DateFormatter().string(from: at)
    }
    capture?.append("app", fields)
    guard settings.verbosity.includes(level) else { return }
    entries.append(DebugEntry(time: at, kind: kind, detail: detail))
    if entries.count > Self.maximumEntries {
      entries.removeFirst(entries.count - Self.maximumEntries)
    }
  }

  /// Whether a ring has been remembered, so the menu can offer to forget it.
  var hasKnownRing: Bool { settings.knownRingIdentifier != nil }

  /// Forgets the ring: its identifier, and where we had got to in its
  /// collections.
  ///
  /// **This cannot remove the Bluetooth bond.** CoreBluetooth has no API to drop
  /// one — the same reason pairing has to be provoked rather than requested — so
  /// the macOS side is the user's to do in System Settings. What this does is
  /// stop us reconnecting straight to that ring and discard a fetch position that
  /// means nothing for a different one.
  func unpair() {
    let forgotten = settings.knownRingIdentifier?.uuidString ?? "none"
    stop()
    // The position deliberately survives: it is tagged with the ring it belongs
    // to, so pairing this one again resumes and any other ring starts clean.
    cursor = nil
    settings.knownRingIdentifier = nil
    recordingCount = 0
    gestureCount = 0
    missedCollections = 0
    ringResetCount = 0
    consecutiveFailures = 0
    lastFiled = nil
    awaitingBluetoothRemoval = true
    note("unpair", "forgot ring \(forgotten); its fetch position is kept in case "
         + "the same ring is paired again. Remove it in System Settings > "
         + "Bluetooth to drop the pairing itself.")
    // Straight back to scanning, so a different ring can be adopted.
    startIfPossible()
  }

  /// Starts the bond-conflict window, and schedules its own expiry.
  ///
  /// The timer matters: while the app is only scanning, nothing else publishes, so
  /// without it the menu bar would keep showing the complaint indefinitely with no
  /// redraw to correct it.
  private func beginBondConflict() {
    let window = RingSession.bondConflictBackoff
    bondConflictUntil = Date().addingTimeInterval(window)
    bondConflictTimer?.invalidate()
    bondConflictTimer = Timer.scheduledTimer(withTimeInterval: window + 1,
                                             repeats: false) { [weak self] _ in
      Task { @MainActor in self?.clearBondConflict() }
    }
  }

  private func clearBondConflict() {
    bondConflictTimer?.invalidate()
    bondConflictTimer = nil
    guard bondConflictUntil != nil else { return }
    bondConflictUntil = nil
  }

  /// Records the full text of a settings failure. The menu only ever shows a
  /// short summary; this is where the detail goes.
  func note(settingsError detail: String) {
    note("settings", detail)
  }

}
