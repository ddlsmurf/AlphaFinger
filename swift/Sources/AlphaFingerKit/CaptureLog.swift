import Foundation

/// Append-only JSONL capture of everything a live session sees.
///
/// The governing rule is **record first, interpret second, and never drop what
/// you cannot parse**. Every event keeps the raw bytes; interpretation goes in a
/// separate `decoded` object, and a decode failure is recorded as `decodeError`
/// *next to the intact bytes* rather than discarding the event. A payload we
/// cannot read today is exactly the material needed to reverse it tomorrow.
///
/// One JSON object per line, flushed per line, so an unplugged ring or a crash
/// still leaves a usable file. See docs/capture-procedure.md.
public final class CaptureLog: @unchecked Sendable {
  /// Payloads at least this large go to a sidecar file instead of inline hex, to
  /// keep the log readable while staying byte-exact.
  public static let blobThresholdBytes = 512

  public let directory: URL

  private let handle: FileHandle
  private let lock = NSLock()
  private let startedAt = Date()
  private let monotonicStart = ProcessInfo.processInfo.systemUptime
  private var sequence = 0
  private var blobCount = 0

  private static let wallFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// Creates `captures/<UTC timestamp>-<command>/` and opens `events.jsonl`.
  public init(command: String, arguments: [String], root: URL) throws {
    let stamp = Self.wallFormatter.string(from: Date())
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: ".", with: "-")
    directory = root.appendingPathComponent("\(stamp)-\(command)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let eventsURL = directory.appendingPathComponent("events.jsonl")
    FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: eventsURL.path) else {
      throw AlphaFingerDecodeError.unsupported("cannot open \(eventsURL.path) for writing")
    }
    self.handle = handle

    try writeMetadata(command: command, arguments: arguments)
    append("session", ["command": command, "arguments": arguments])
  }

  private func writeMetadata(command: String, arguments: [String]) throws {
    let process = ProcessInfo.processInfo
    let metadata: [String: Any] = [
      "command": command,
      "arguments": arguments,
      "startedAt": Self.wallFormatter.string(from: startedAt),
      // No host name. `ProcessInfo.hostName` resolves the fully-qualified name
      // over mDNS -- it returns "<name>.local" and takes ~20 ms -- which made
      // macOS ask for local network permission the moment a capture started, and
      // since the app auto-starts, that meant at launch. The value was never read
      // back either. The log already sits on the machine that wrote it, so the
      // name added nothing.
      "operatingSystem": process.operatingSystemVersionString,
      "captureFormatVersion": 1,
    ]
    let data = try JSONSerialization.data(withJSONObject: metadata,
                                          options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("meta.json"))
  }

  /// Writes one event. Never throws: losing the log must not abort a session that
  /// is holding a live BLE connection open.
  public func append(_ kind: String, _ fields: [String: Any] = [:]) {
    lock.lock()
    defer { lock.unlock() }

    sequence += 1
    var event: [String: Any] = fields
    event["seq"] = sequence
    event["kind"] = kind
    event["wall"] = Self.wallFormatter.string(from: Date())
    // Relative timing matters more than absolute for protocol inference.
    event["mono"] = ProcessInfo.processInfo.systemUptime - monotonicStart

    let line: Data
    do {
      line = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
    } catch {
      // Fall back to a diagnostic the log can still carry, rather than dropping.
      let fallback = "{\"kind\":\"error\",\"seq\":\(sequence),"
        + "\"message\":\"event not JSON-serialisable: \(kind)\"}"
      handle.write(Data(fallback.utf8))
      handle.write(Data("\n".utf8))
      return
    }
    handle.write(line)
    handle.write(Data("\n".utf8))
  }

  /// Describes a byte payload for embedding in an event.
  ///
  /// Small payloads are inlined as hex; large ones are written to a sidecar and
  /// referenced by name. Either way the bytes are preserved exactly.
  public func payload(_ bytes: [UInt8], label: String) -> [String: Any] {
    var described: [String: Any] = ["length": bytes.count]
    if bytes.count >= Self.blobThresholdBytes {
      lock.lock()
      blobCount += 1
      let name = String(format: "blob-%04d-%@.bin", blobCount, label)
      lock.unlock()
      let url = directory.appendingPathComponent(name)
      try? Data(bytes).write(to: url)
      described["blob"] = name
      // Keep a prefix inline so the log alone is still readable.
      described["hexPrefix"] = Self.hex(Array(bytes.prefix(64)))
    } else {
      described["hex"] = Self.hex(bytes)
    }
    return described
  }

  public static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  public func close() {
    append("sessionEnd", [:])
    try? handle.close()
  }
}

/// Converts arbitrary CoreBluetooth dictionary values into something
/// `JSONSerialization` accepts, without losing anything.
///
/// Advertisement dictionaries carry `Data`, `NSNumber`, `CBUUID` and arrays of
/// those. An unrecognised type is stringified rather than dropped -- a key we
/// have never seen before is precisely what a capture exists to surface.
public enum JSONSafe {
  public static func value(_ input: Any) -> Any {
    switch input {
    case let data as Data:
      return ["length": data.count, "hex": CaptureLog.hex([UInt8](data))]
    case let number as NSNumber:
      return number
    case let string as String:
      return string
    case let array as [Any]:
      return array.map { value($0) }
    case let dictionary as [String: Any]:
      return dictionary.mapValues { value($0) }
    default:
      return String(describing: input)
    }
  }

  public static func dictionary(_ input: [String: Any]) -> [String: Any] {
    input.mapValues { value($0) }
  }
}
