import Foundation

/// Runs a user-configured shell command in response to a gesture.
///
/// Context reaches the command through **environment variables**, never by
/// interpolation into the command string. A timestamp or ring identifier spliced
/// into a command line would be one odd character away from becoming shell
/// syntax; as an environment variable it is inert whatever it contains.
public struct ShellAction {
  /// One line of a command's output, with when it reached us.
  ///
  /// The time is when the app *read* the line, not when the command wrote it: a
  /// program using C stdio into a pipe block-buffers, and its output can arrive in
  /// one lump however long it took to produce. `/bin/sh` writes each `echo`
  /// straight through, so a shell script's lines are stamped as they happen.
  public struct OutputLine: Sendable {
    public let stream: String
    public let line: String
    public let at: Date
  }

  public struct Outcome: Sendable {
    public let command: String
    public let exitCode: Int32
    public let outputLines: [OutputLine]
    /// How long the command actually took. Reported so the log can say what a
    /// command cost without anyone subtracting timestamps by hand.
    public let durationSeconds: Double
    public var succeeded: Bool { exitCode == 0 }

    /// Nothing outside this type reads these; they exist so a caller that wants
    /// the whole of one stream does not have to filter and join it itself.
    public var standardOutput: String { joined("stdout") }
    public var standardError: String { joined("stderr") }

    private func joined(_ stream: String) -> String {
      outputLines.filter { $0.stream == stream }.map(\.line).joined(separator: "\n")
    }
  }

  public enum ActionError: Error, CustomStringConvertible {
    case launchFailed(command: String, underlying: String)

    public var description: String {
      switch self {
      case let .launchFailed(command, underlying):
        return "could not run '\(command)': \(underlying)"
      }
    }
  }

  /// Commands are given this long before being terminated, so a hung script
  /// cannot stall the pipeline behind it.
  ///
  /// Generous, because transcribing a recording is the obvious thing to do with
  /// this feature and thirty seconds does not fit it. Commands run on a serial
  /// queue, so this is also the longest one hung command can delay the next.
  public static let timeoutSeconds: TimeInterval = 300

  /// How long a terminated command has to exit before it is killed outright.
  /// A script that traps SIGTERM must not be able to hold the queue.
  static let terminationGraceSeconds: TimeInterval = 2

  public static let shellPath = "/bin/sh"
  public static let environmentPrefix = "ALPHAFINGER_"

  public init() {}

  /// Runs `command` with `context` exposed as `ALPHAFINGER_`-prefixed variables.
  ///
  /// Context never reaches the command as text: a filename or timestamp spliced
  /// into a command line is one odd character from becoming shell syntax, while
  /// an environment variable is inert whatever it holds.
  @discardableResult
  public func run(command: String, environment context: [String: String],
                  timeoutSeconds: TimeInterval = ShellAction.timeoutSeconds) throws -> Outcome {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return Outcome(command: "", exitCode: 0, outputLines: [], durationSeconds: 0)
    }
    let startedAt = Date()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.shellPath)
    process.arguments = ["-c", trimmed]

    var environment = ProcessInfo.processInfo.environment
    for (key, value) in context {
      environment["\(Self.environmentPrefix)\(key)"] = value
    }
    process.environment = environment

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
    } catch {
      throw ActionError.launchFailed(command: trimmed,
                                     underlying: String(describing: error))
    }

    // Both pipes must be drained *while* the command runs, not after it: a
    // command that fills a pipe buffer blocks forever otherwise, with each side
    // waiting on the other. Draining on separate threads is also what makes the
    // timeout real -- reading to end-of-file first would block until the command
    // exited of its own accord, whatever the deadline said.
    let drain = DispatchGroup()
    let readers = DispatchQueue(label: "alphafinger.shell.io", attributes: .concurrent)
    let collected = OutputBox()
    for (handle, stream) in [(outputPipe.fileHandleForReading, "stdout"),
                             (errorPipe.fileHandleForReading, "stderr")] {
      readers.async(group: drain) {
        // `availableData` returns as soon as there are bytes, and empty at EOF --
        // so each chunk can be stamped when it arrives instead of the whole stream
        // being stamped when the command exits.
        while true {
          let chunk = handle.availableData
          if chunk.isEmpty { break }
          collected.ingest(chunk, stream: stream, at: Date())
        }
        collected.finish(stream: stream)
      }
    }

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      let killAfter = Date().addingTimeInterval(Self.terminationGraceSeconds)
      while process.isRunning && Date() < killAfter {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    // Only now can this return: the readers hold the last open descriptors, and
    // they finish as soon as the command's are closed.
    drain.wait()

    return Outcome(command: trimmed,
                   exitCode: process.terminationStatus,
                   outputLines: collected.lines,
                   durationSeconds: Date().timeIntervalSince(startedAt))
  }
}

/// Somewhere for two reader threads to put the lines they read.
///
/// Both threads write here, so the lock is what makes that ordering explicit
/// rather than assumed. It also holds the tail of a chunk that ended mid-line,
/// per stream, so a line split across two reads is not split in the log.
private final class OutputBox: @unchecked Sendable {
  private let lock = NSLock()
  private var collected: [(order: Int, line: ShellAction.OutputLine)] = []
  private var partial: [String: String] = [:]
  private var arrivals = 0

  func ingest(_ data: Data, stream: String, at time: Date) {
    lock.lock()
    defer { lock.unlock() }
    let text = (partial[stream] ?? "") + String(decoding: data, as: UTF8.self)
    var pieces = text.components(separatedBy: "\n")
    // The last piece has no newline after it yet: either the chunk ended mid-line
    // or it ended exactly on one, in which case this is empty and harmless.
    partial[stream] = pieces.removeLast()
    for piece in pieces { append(piece, stream: stream, at: time) }
  }

  /// Whatever a stream ended with, if it never sent a final newline.
  func finish(stream: String) {
    lock.lock()
    defer { lock.unlock() }
    if let remainder = partial.removeValue(forKey: stream) {
      append(remainder, stream: stream, at: Date())
    }
  }

  /// In the order the lines arrived. The two streams are read concurrently, so
  /// sorting by time is what makes the log read chronologically -- and the arrival
  /// counter is the tiebreak, because Swift's sort is not stable and two lines
  /// sharing a timestamp would otherwise swap between runs.
  var lines: [ShellAction.OutputLine] {
    lock.lock()
    defer { lock.unlock() }
    return collected
      .sorted { ($0.line.at, $0.order) < ($1.line.at, $1.order) }
      .map(\.line)
  }

  /// Caller holds the lock.
  private func append(_ piece: String, stream: String, at time: Date) {
    let trimmed = piece.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    arrivals += 1
    collected.append((arrivals, ShellAction.OutputLine(stream: stream, line: trimmed,
                                                       at: time)))
  }
}
