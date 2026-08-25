import AppKit
import SwiftUI

/// Everything the app knows, in one place, so the menu can stay silent.
struct DebugView: View {
  @EnvironmentObject private var coordinator: RingCoordinator
  @State private var filter = ""

  private var visible: [DebugEntry] {
    guard !filter.isEmpty else { return coordinator.entries }
    let needle = filter.lowercased()
    return coordinator.entries.filter {
      $0.kind.lowercased().contains(needle) || $0.detail.lowercased().contains(needle)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
        Button("Reveal capture log") {
          if let url = coordinator.captureDirectory {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }
        .disabled(coordinator.captureDirectory == nil)
        Button("Copy") { copyAll() }
      }
      .padding(8)

      Table(visible) {
        TableColumn("Time") { entry in
          Text(entry.time, format: .dateTime.hour().minute().second())
            .monospacedDigit()
        }
        .width(80)
        TableColumn("Kind") { entry in
          Text(entry.kind)
            .foregroundStyle(entry.kind == "error" ? .red : .primary)
        }
        .width(110)
        TableColumn("Detail") { entry in
          Text(entry.detail).textSelection(.enabled)
        }
      }

      HStack {
        Text("\(visible.count) of \(coordinator.entries.count) entries")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("Full JSONL capture is written alongside; this view is a summary.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .padding(8)
    }
  }

  private func copyAll() {
    let text = visible
      .map { "\($0.time) \($0.kind) \($0.detail)" }
      .joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
