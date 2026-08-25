import Foundation

/// How the app should behave when a recording or gesture arrives.
public struct RingPipelineSettings: Sendable, Equatable {
  /// Where every recording is filed. One folder: the tap count is in the
  /// filename instead, which keeps related recordings together and makes the
  /// gesture visible without opening anything.
  public var recordingsDirectory: URL
  /// Run after a recording is filed, and after taps with no recording. One
  /// command rather than one per case: which it was is in `ALPHAFINGER_GESTURE`,
  /// and a script that cares can branch on it. Empty means nothing runs.
  public var command: String
  /// Only consulted when a collection has no usable press record.
  public var recordingThresholdSeconds: Double

  public init(recordingsDirectory: URL,
              command: String = "",
              recordingThresholdSeconds: Double = RecordingClassifier.defaultThresholdSeconds) {
    self.recordingsDirectory = recordingsDirectory
    self.command = command
    self.recordingThresholdSeconds = recordingThresholdSeconds
  }
}

/// What the pipeline did, for the menu and the debug window.
public enum RingOutcome: Sendable {
  case savedRecording(RecordingWriter.Result, isDoubleTap: Bool,
                      pattern: String, reason: ClassificationReason)
  /// Emitted the moment a command begins running, so the log shows a start as
  /// well as an end. Without it a recording is followed by several silent seconds
  /// and then everything at once, which reads like a command that started late.
  ///
  /// `queuedSeconds` is the wait between being dispatched and actually running.
  /// Commands share one serial queue, so this is what distinguishes a slow command
  /// from one stuck behind another.
  case startedCommand(label: String, command: String, queuedSeconds: Double)
  /// `recording` is the file the command was given, when there was one. A
  /// gesture command has none.
  case ranCommand(ShellAction.Outcome, label: String, recording: URL?)
  case ignored(reason: String)
  case failed(String)
  case ringReset(String)
  /// Detail worth recording but not worth acting on. Verbosity decides whether
  /// it is shown; the capture log always keeps it.
  case detail(String)
}

/// Collections in, filed recordings and fired commands out.
///
/// Everything above the transport lives here, so it can be driven from a replay
/// source and verified without a ring.
public final class RingPipeline {
  public var settings: RingPipelineSettings
  public var onOutcome: ((RingOutcome) -> Void)?

  private let assembler = CollectionAssembler()
  private let writer = RecordingWriter()
  private let shell = ShellAction()
  /// Commands run here, never on the caller's thread. `accept` is driven from the
  /// main actor, and a post-recording command that transcribes audio takes tens
  /// of seconds -- running it inline froze the menu, both windows and the fetch
  /// loop behind it for that whole time.
  ///
  /// Serial on purpose: two recordings filed together must not start two
  /// transcriptions at once, and commands should fire in the order their
  /// recordings did.
  private let commandQueue = DispatchQueue(label: "alphafinger.commands")
  private let cursor: CollectionCursor?
  private var debouncer: GestureDebouncer!
  /// Lowest collection index whose handling failed this session.
  ///
  /// The cursor must never move past it. Gestures and recordings complete out of
  /// order, so without this a later gesture would advance the cursor over an
  /// earlier recording that failed to save -- and that recording would never be
  /// fetched again.
  private var lowestFailedIndex: UInt32?

  public init(settings: RingPipelineSettings,
              cursor: CollectionCursor? = nil,
              now: @escaping () -> Date = Date.init) {
    self.settings = settings
    self.cursor = cursor
    self.debouncer = GestureDebouncer(now: now) { [weak self] gesture in
      self?.handle(gesture)
    }
  }

  public func accept(_ collection: RingCollection) {
    if cursor?.hasSeen(collection.index) == true {
      onOutcome?(.ignored(reason: "collection \(collection.index) already handled"))
      return
    }
    let classifier = RecordingClassifier(thresholdSeconds: settings.recordingThresholdSeconds)
    for group in assembler.accept(collection) {
      dispatch(classifier.classify(group))
    }
  }

  /// Call when the ring has restarted its collection numbering.
  ///
  /// Clears `lowestFailedIndex` as well as the in-flight state: it refers to an
  /// index in the old numbering, and left in place it would clamp the new cursor
  /// forever at a value that no longer means anything.
  public func ringDidReset(_ reason: String) {
    finish()
    assembler.ringDidReset()
    lowestFailedIndex = nil
    onOutcome?(.ringReset(reason))
  }

  /// Call when the source has handed over everything the ring currently offers.
  ///
  /// This fires a pending gesture without waiting for a press that may never come,
  /// and it deliberately **leaves open multipart runs open**. A recording spans
  /// many collections and the ring drops the link roughly every ten seconds, so a
  /// run is routinely part-fetched in one batch and finished in the next; closing
  /// it here is what previously turned one recording into a directory of
  /// sub-second fragments that then overwrote each other.
  ///
  /// A run whose final part never arrives is bounded two ways: the 512-part cap in
  /// `CollectionAssembler`, and `stalledRunTimeout` below.
  public func endOfBatch() {
    let classifier = RecordingClassifier(thresholdSeconds: settings.recordingThresholdSeconds)
    for group in assembler.flushRunsIdle(longerThan: Self.stalledRunTimeout) {
      dispatch(classifier.classify(group))
    }
    // Deliberately no gesture flush. The ring hands over a tap while the button is
    // still held, so the recording that would absorb it does not exist yet -- it
    // is only stored on release. Flushing here fired the tap's command seconds
    // before the recording arrived. A held gesture waits for `ringWentIdle`, with
    // the staleness bound below as the backstop for a ring that goes quiet.
    if debouncer.hasPendingOlderThan(GestureDebouncer.stalenessThreshold) {
      onOutcome?(.detail("releasing a gesture held past the point of being absorbed"))
      debouncer.flush()
    }
  }

  /// The ring says it has nothing pending and is not recording.
  ///
  /// Nothing more is coming that could absorb a held gesture, so it can be acted
  /// on. This is what makes a tap on its own fire promptly rather than waiting for
  /// whatever the ring does next.
  public func ringWentIdle() {
    debouncer.flush()
  }

  /// How long a run may sit without a new part before it is written anyway.
  /// Writing a truncated recording beats holding it until the process exits.
  public static let stalledRunTimeout: TimeInterval = 300

  /// Call when nothing more is coming at all -- shutdown, or the end of a replay.
  /// Unlike `endOfBatch`, this closes every open run.
  public func finish() {
    let classifier = RecordingClassifier(thresholdSeconds: settings.recordingThresholdSeconds)
    for group in assembler.flush() {
      dispatch(classifier.classify(group))
    }
    debouncer.flush()
  }

  private func dispatch(_ event: RingEvent) {
    switch event {
    case let .recording(group, presses, reason):
      // A recording absorbs the tap that preceded it. The ring stored that tap as
      // its own collection the moment it ended, and this recording's press record
      // already accounts for it -- emitting both runs the command twice for one
      // gesture. This used to call flush(), which emits rather than discards, and
      // did exactly that.
      if debouncer.discardPending(absorbedBy: group.startIndex,
                                  at: group.ringTimestamp) {
        onOutcome?(.detail("group \(group.startIndex): absorbed the tap before it"))
      }
      let pattern = presses?.patternDescription ?? "unknown"
      onOutcome?(.detail("group \(group.startIndex): recording, presses \(pattern), "
                         + "decided by \(reason.rawValue)"))
      // "Double tap" means the gesture included a tap before the recording.
      let hadTap = (presses?.tapCount ?? 0) >= 1
      save(group, isDoubleTap: hadTap, pattern: pattern, reason: reason)

    case let .gesture(tapCount, timestamp, startIndex, battery, reason):
      onOutcome?(.detail("group \(startIndex): \(counted(Int(tapCount), "tap")), "
                         + "decided by \(reason.rawValue)"))
      debouncer.accept(count: tapCount, at: timestamp, startIndex: startIndex,
                       batteryMilliVolts: battery)
    }
  }

  private func save(_ group: CollectionGroup, isDoubleTap: Bool,
                    pattern: String, reason: ClassificationReason) {
    do {
      let result = try writer.write(group, to: settings.recordingsDirectory,
                                    gesture: isDoubleTap ? "double-tap" : "recording",
                                    pressPattern: pattern,
                                    classifiedBy: reason.rawValue)
      // Only now is it safe to advance. `write` puts the files in place
      // atomically, so reaching here means they are on disk complete; anything
      // that threw leaves the cursor untouched and the collections are fetched
      // again next time.
      advance(to: group.lastIndex)
      onOutcome?(.savedRecording(result, isDoubleTap: isDoubleTap,
                                 pattern: pattern, reason: reason))
      runPostRecording(result, group: group, isDoubleTap: isDoubleTap, pattern: pattern)
    } catch {
      recordFailure(at: group.startIndex)
      onOutcome?(.failed("collection group \(group.startIndex): \(error)"))
    }
  }

  private func recordFailure(at index: UInt32) {
    lowestFailedIndex = min(lowestFailedIndex ?? index, index)
  }

  /// Advances the cursor, but never past a collection that failed.
  private func advance(to index: UInt32) {
    var target = index
    if let failed = lowestFailedIndex {
      guard failed > 0 else { return }
      target = min(target, failed - 1)
    }
    if let last = cursor?.lastCompletedIndex, target <= last { return }
    do {
      try cursor?.markCompleted(throughIndex: target)
    } catch {
      onOutcome?(.failed("could not persist the collection cursor: \(error)"))
    }
  }

  /// Runs only after the file is written and the cursor advanced, so a failing
  /// command can never cost a recording.
  private func runPostRecording(_ result: RecordingWriter.Result,
                                group: CollectionGroup,
                                isDoubleTap: Bool, pattern: String) {
    let command = settings.command
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else {
      // Said out loud. Returning in silence here made a stale settings snapshot
      // impossible to tell apart from a command that ran and did nothing.
      onOutcome?(.ignored(reason: "recording filed with no command configured"))
      return
    }

    var environment = [
      "GESTURE": Self.recordingGesture,
      "TAP_COUNT": String(group.buttonPress?.tapCount ?? 0),
      "START_INDEX": String(group.startIndex),
      // The one thing a command cannot work out for itself, and the only place a
      // tap -- which has no file -- can be told where anything belongs.
      "RECORDINGS_DIR": settings.recordingsDirectory.path,
      "FILE": result.audioURL.path,
      "METADATA_FILE": result.metadataURL.path,
      "PRESS_PATTERN": pattern,
      "DURATION": String(format: "%.3f", result.durationSeconds),
    ]
    // Absent, not invented, when the ring never had a clock reading: a script can
    // then default it however suits, and one that needs a real time can tell.
    if let timestamp = group.ringTimestamp {
      environment["TIMESTAMP"] = ISO8601DateFormatter().string(from: timestamp)
    }
    if let battery = group.batteryMilliVolts {
      environment["BATTERY_MILLIVOLTS"] = String(battery)
    }
    run(command, environment: environment,
        label: Self.recordingGesture, recording: result.audioURL)
  }

  private func handle(_ gesture: RingGesture) {
    let label = "\(gesture.count)-tap"
    let command = settings.command
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else {
      onOutcome?(.ignored(reason: "\(label) with no command configured"))
      advance(past: gesture)
      return
    }
    // Deliberately none of the recording variables: there is no file, so a script
    // can test for one to know which of the two it is handling.
    var environment: [String: String] = [
      "GESTURE": label,
      "TAP_COUNT": String(gesture.count),
      "START_INDEX": String(gesture.startIndex),
      "RECORDINGS_DIR": settings.recordingsDirectory.path,
    ]
    if let timestamp = gesture.timestamp {
      environment["TIMESTAMP"] = ISO8601DateFormatter().string(from: timestamp)
    }
    if let battery = gesture.batteryMilliVolts {
      environment["BATTERY_MILLIVOLTS"] = String(battery)
    }
    // Before the dispatch, not after it: the cursor never depended on what the
    // command returned, and it must not wait for one to find out.
    advance(past: gesture)
    run(command, environment: environment, label: label, recording: nil)
  }

  /// `ALPHAFINGER_GESTURE` for a filed recording. Taps use "1-tap", "2-tap"…
  public static let recordingGesture = "recording"

  /// Hands one command to the queue and returns immediately.
  ///
  /// Captures the shell and the outcome callback by value rather than `self`, so
  /// nothing on the queue ever touches pipeline state. `onOutcome` already hops
  /// to the main actor at its other end.
  private func run(_ command: String, environment: [String: String],
                   label: String, recording: URL?) {
    let shell = self.shell
    let report = onOutcome
    let dispatchedAt = Date()
    commandQueue.async {
      report?(.startedCommand(label: label, command: command,
                              queuedSeconds: Date().timeIntervalSince(dispatchedAt)))
      do {
        let outcome = try shell.run(command: command, environment: environment)
        report?(.ranCommand(outcome, label: label, recording: recording))
      } catch {
        report?(.failed("\(label) command: \(error)"))
      }
    }
  }

  /// Blocks until every queued command has finished.
  ///
  /// `finish()` deliberately does not call this: it runs on the main actor during
  /// teardown, and waiting there would reintroduce the freeze this queue exists
  /// to remove. Tests that assert on a command's effects need it.
  public func waitForCommands() {
    commandQueue.sync {}
  }

  private func advance(past gesture: RingGesture) {
    advance(to: gesture.startIndex + max(gesture.count, 1) - 1)
  }
}
