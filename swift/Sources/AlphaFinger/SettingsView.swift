import AppKit
import AlphaFingerKit
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    Form {
      Section("Where recordings go") {
        FolderRow(title: "Recordings", url: settings.recordingsDirectory) {
          settings.recordingsDirectory = $0
        }
        Text("Named <ring time>-<ring id>-tap<N>-<index>.wav, where N is how many "
             + "taps preceded the recording: tap0 is a plain recording, tap1 is a "
             + "tap then a recording. The time is the ring's own clock, so files "
             + "are dated when they were recorded, not when they synced.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Command") {
        TextField("Runs after any taps or recording", text: $settings.command,
                  prompt: Text("optional — path to a script, e.g. ~/bin/on-recording.sh"))
        CommandWarning(command: settings.command)
        VariableHelp(
          lead: "The path to an executable script: an absolute path, with the "
            + "executable bit (chmod +x) and a #! line on top. It is run with "
            + "/bin/sh, so a bare command works too, but a script is what these "
            + "variables are for. One command for both cases — after a recording "
            + "is filed, and after taps with no recording. Both get",
          variables: ["$ALPHAFINGER_GESTURE", "$ALPHAFINGER_TAP_COUNT",
                      "$ALPHAFINGER_START_INDEX", "$ALPHAFINGER_RECORDINGS_DIR"],
          trail: nil)
        VariableHelp(
          lead: "GESTURE says which it was — \"recording\", or \"1-tap\", "
            + "\"2-tap\"… TAP_COUNT is how many taps: for a recording that is how "
            + "many came before it, so 0 for a plain one. A recording also gets",
          variables: ["$ALPHAFINGER_FILE", "$ALPHAFINGER_METADATA_FILE",
                      "$ALPHAFINGER_DURATION", "$ALPHAFINGER_PRESS_PATTERN"],
          trail: "None of those four are set for a tap, so testing for FILE is how "
            + "a script tells the two apart.")
        VariableHelp(
          lead: "Two more arrive only when the ring had them to give, so default "
            + "them rather than requiring them:",
          variables: ["$ALPHAFINGER_TIMESTAMP", "$ALPHAFINGER_BATTERY_MILLIVOLTS"],
          trail: "TIMESTAMP is absent when the ring's clock was never set — a "
            + "recording made before that has no time to report. "
            + "BATTERY_MILLIVOLTS is absent when the collection carried no reading.")
      }

      Section("Notifications") {
        Toggle("Notify when a recording is saved", isOn: $settings.notifyOnRecording)
        Text("Its banner fades on its own rather than interrupting. A command "
             + "that exits non-zero always notifies, whatever this is set to. "
             + "Clicking either notification reveals the recording in Finder.")
          .font(.caption).foregroundStyle(.secondary)
        Text("These probably will not appear at all. You built this app yourself, "
             + "so it is unsigned, and macOS tends to drop notifications from an "
             + "app it cannot identify. Nothing here can fix that — signing it "
             + "can. Your own command can notify instead, and that always works:")
          .font(.caption).foregroundStyle(.secondary)
          .textSelection(.enabled)
        CopyableName(#"osascript -e 'display notification "saved" with title "AlphaFinger"'"#)
      }

      Section("Debug output") {
        Picker("Verbosity", selection: $settings.verbosity) {
          ForEach(DebugVerbosity.allCases) { level in
            Text(level.label).tag(level)
          }
        }
        Text(settings.verbosity.description
             + ". The JSONL capture on disk always records everything, "
             + "whatever this is set to.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Tuning") {
        HStack {
          Text("Recording threshold")
          Slider(value: $settings.thresholdSeconds, in: 0.1 ... 3.0)
          Text(String(format: "%.1f s", settings.thresholdSeconds))
            .monospacedDigit().frame(width: 50, alignment: .trailing)
        }
        Text("Only used when a collection has no usable press record. Normally "
             + "the ring states the gesture outright and this is ignored.")
          .font(.caption).foregroundStyle(.secondary)

        HStack {
          Text("Idle link check")
          Slider(value: $settings.pollSeconds, in: 5 ... 120)
          Text("\(Int(settings.pollSeconds)) s")
            .monospacedDigit().frame(width: 50, alignment: .trailing)
        }
        Text("A backstop only. Recordings arrive when the ring asks for a "
             + "connection, not on this timer, so changing this will not make them "
             + "arrive sooner. It only matters if a link stays up with nothing "
             + "left to fetch.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
  }

  /// `NSOpenPanel` is what grants the app durable access to a folder the user
  /// picked, which is why folders cannot simply be typed in.
  static func chooseDirectory(prompt: String, startingAt: URL? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    // The folder the user wants may not exist yet -- the default one does not
    // until the first recording lands -- so let them make it from here.
    panel.canCreateDirectories = true
    panel.prompt = prompt
    // Open where the current choice points, even if it has not been created yet;
    // AppKit falls back to the nearest existing ancestor.
    panel.directoryURL = startingAt
    return panel.runModal() == .OK ? panel.url : nil
  }
}

/// Help text whose variable names can be selected and copied.
///
/// `Text` in a SwiftUI window is not selectable, and these are names you have to
/// retype exactly into a shell command — a typo produces an empty variable and a
/// command that silently does the wrong thing. The names are laid out as
/// individually selectable fields, each with a copy button.
private struct VariableHelp: View {
  let lead: String
  let variables: [String]
  var trail: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(lead).font(.caption).foregroundStyle(.secondary)
      // A flowing grid rather than a row: six names do not fit on one line, and a
      // fixed column count would strand the short ones.
      FlowLayout(spacing: 6) {
        ForEach(variables, id: \.self) { name in
          CopyableName(name)
        }
      }
      if let trail {
        Text(trail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

/// One variable name: selectable, and copyable in a click.
private struct CopyableName: View {
  let name: String
  @State private var copied = false

  init(_ name: String) { self.name = name }

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(name, forType: .string)
      copied = true
      Task {
        try? await Task.sleep(for: .seconds(1.2))
        copied = false
      }
    } label: {
      HStack(spacing: 4) {
        // textSelection makes the name selectable with the cursor as well, for
        // anyone who wants half of it.
        Text(name).font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 9))
          .foregroundStyle(copied ? Color.green : Color.secondary)
      }
      .padding(.horizontal, 6).padding(.vertical, 3)
      .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
    }
    .buttonStyle(.plain)
    .help(copied ? "Copied" : "Copy \(name)")
  }
}

/// Wraps its children onto as many lines as they need.
private struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                    cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0; y += lineHeight + spacing; lineHeight = 0
      }
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
    return CGSize(width: proposal.width ?? x, height: y + lineHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                     subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}

private struct FolderRow: View {
  let title: String
  let url: URL?
  let onChoose: (URL) -> Void
  /// Re-checked whenever the view re-renders, so the row stops saying "will be
  /// created" once the first recording has actually made the folder.
  private var exists: Bool {
    guard let url else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        // Tilde-abbreviated: the absolute path is what made this row, and with it
        // the whole window, far wider than it needs to be.
        Text(url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "not set")
          .foregroundStyle(url == nil ? .secondary : .primary)
          .lineLimit(1).truncationMode(.head)
        if url != nil, !exists {
          Text("created when the first recording arrives")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Button("Choose…") {
        if let chosen = SettingsView.chooseDirectory(prompt: "Choose \(title)",
                                                     startingAt: url) {
          onChoose(chosen)
        }
      }
    }
  }
}

/// Warns about the one command that fails with nothing to show for it.
///
/// A bare path to a file without the executable bit exits 126 and prints nothing,
/// which explains itself to nobody -- and a bare path is exactly what this field
/// now encourages. Only a warning: the field takes any shell command, and a
/// heuristic has no business refusing to save one.
private struct CommandWarning: View {
  let command: String

  private var problem: String? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    // Anything with a space is a command line, not a path to check.
    guard !trimmed.isEmpty, !trimmed.contains(" "),
          trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
    let path = (trimmed as NSString).expandingTildeInPath
    let manager = FileManager.default
    guard manager.fileExists(atPath: path) else {
      return "No such file: \(path)"
    }
    guard manager.isExecutableFile(atPath: path) else {
      return "Not executable — run: chmod +x \(path)"
    }
    return nil
  }

  var body: some View {
    if let problem {
      Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
    }
  }
}
