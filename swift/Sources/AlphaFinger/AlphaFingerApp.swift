import AppKit
import AlphaFingerKit
import SwiftUI

@main
struct AlphaFingerApp: App {
  @StateObject private var settings: AppSettings
  @StateObject private var coordinator: RingCoordinator
  @StateObject private var ticker = Ticker()

  init() {
    // Built once and shared. Writing `= AppSettings()` on the property as well
    // would construct a second one, resolve its bookmarks, and leak a
    // security-scoped access before being thrown away.
    let settings = AppSettings()
    _settings = StateObject(wrappedValue: settings)
    _coordinator = StateObject(wrappedValue: RingCoordinator(settings: settings))
  }

  var body: some Scene {
    // The label reads no observable state, so the Scene body does not re-evaluate
    // when the coordinator publishes -- which it does constantly. Previously the
    // icon read `coordinator.isConnected` here, so every connect and disconnect
    // re-evaluated the whole Scene graph including both Windows below, and an
    // LSUIElement app churning its windows hands activation to Finder.
    MenuBarExtra {
      MenuContent()
        .environmentObject(settings)
        .environmentObject(coordinator)
        .environmentObject(ticker)
    } label: {
      MenuBarIcon(coordinator: coordinator)
    }

    Window("AlphaFinger Settings", id: "settings") {
      SettingsView().environmentObject(settings)
    }
    .defaultSize(width: 560, height: 420)

    Window("AlphaFinger Debug", id: "debug") {
      DebugView().environmentObject(coordinator)
    }
    .defaultSize(width: 760, height: 480)
  }
}

/// The battery reading and its age.
///
/// Split out because it is the only thing that has to re-render on a clock. It
/// observes `Ticker`, which nothing else observes, so the 5-second tick redraws
/// this one line and nothing else.
struct AgeLine: View {
  @ObservedObject var coordinator: RingCoordinator
  @EnvironmentObject private var ticker: Ticker

  var body: some View {
    if let battery = coordinator.batterySummary(asOf: ticker.now) {
      Text(battery)
    }
  }
}

/// The menubar icon, isolated so that coordinator updates redraw only this and not
/// the whole Scene graph.
struct MenuBarIcon: View {
  @ObservedObject var coordinator: RingCoordinator

  var body: some View {
    Image(nsImage: MenuBarIcon.render(coordinator.status))
  }

  /// Menu-bar icons are 18 pt. Drawn as a template image so macOS tints it —
  /// inverting with the bar and dimming when the bar is inactive — which is why
  /// state is carried by shape rather than colour.
  static let pointSize: CGFloat = 18

  static func render(_ status: RingCoordinator.Status) -> NSImage {
    let (band, mark) = status.glyph
    let size = NSSize(width: pointSize, height: pointSize)
    let image = NSImage(size: size, flipped: true) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      NSColor.black.setFill()
      NSColor.black.setStroke()
      RingGlyph.draw(band: band, mark: mark, in: context, size: rect.size)
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = status.summary
    return image
  }
}

/// Deliberately quiet: state, the last thing filed, and the way in to everything
/// else. All detail lives in the debug window.
struct MenuContent: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var coordinator: RingCoordinator
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    // One line saying what is happening, in the user's terms, then the battery.
    Text(coordinator.status.summary)
    AgeLine(coordinator: coordinator)

    // Then only what needs acting on. A menu that lists everything it knows is a
    // log, not a menu.
    switch coordinator.status {
    case .bondHeldElsewhere:
      // Nothing the app can do: the ring keeps one bond and the phone has it.
      Text("Unpair it on your phone, then it will connect here")
    case .attention:
      if coordinator.pairingProblem != nil {
        Text("The ring would not pair")
        Button("Try Pairing Again") { coordinator.retryPairing() }
        Button("Open Bluetooth Settings…") { openBluetoothSettings() }
      } else {
        Text("\(coordinator.consecutiveFailures) failed attempts — still trying")
        Button("Try Again Now") { coordinator.retryPairing() }
      }
    case .noRing where coordinator.awaitingBluetoothRemoval:  // just unpaired
      Text("Also remove it in Bluetooth settings")
      Button("Open Bluetooth Settings…") { openBluetoothSettings() }
    default:
      EmptyView()
    }

    if let problem = settings.lastError {
      Text("⚠︎ \(problem)")
    }
    if coordinator.missedCollections > 0 {
      Text("⚠︎ \(coordinator.missedCollections) lost to ring storage")
    }
    if coordinator.ringResetCount > 0 {
      Text("⚠︎ Ring was reset — refetching from the start")
    }

    Divider()
    if let last = coordinator.lastFiled {
      Text("Last: \(MenuContent.shorten(last))")
    }
    Text("\(counted(coordinator.recordingCount, "recording")), "
         + "\(counted(coordinator.gestureCount, "gesture"))")
    Button("Open \(recordingsFolderLabel)") { openRecordingsFolder() }

    Divider()
    Button("Settings…") { openWindow(id: "settings"); activate() }
    Button("Debug…") { openWindow(id: "debug"); activate() }
    if coordinator.hasKnownRing {
      Button("Unpair Ring…") { confirmUnpair() }
    }
    Divider()
    Button("Quit") { NSApplication.shared.terminate(nil) }
  }

  /// Unpairing throws away the fetch position as well as the ring, so it asks
  /// first -- and says plainly what it can and cannot do, because it cannot
  /// actually remove the Bluetooth bond.
  private func confirmUnpair() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Unpair this ring?"
    alert.informativeText = """
      AlphaFinger will forget this ring and start looking for one again. \
      Recordings already saved are kept. Pair the same ring and it picks up where \
      it left off; a different ring starts from its first recording.
      """
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Unpair")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    coordinator.unpair()
    offerBluetoothRemoval()
  }

  /// The half of unpairing this app is not allowed to do.
  ///
  /// Forgetting the ring here leaves the macOS Bluetooth bond intact, and there is
  /// no CoreBluetooth API to drop one -- it is System Settings or nothing. Asked
  /// straight after the unpair, while it is obvious why, rather than left as a
  /// line in the menu that is easy to read past. The menu keeps its reminder for
  /// anyone who says no.
  private func offerBluetoothRemoval() {
    let alert = NSAlert()
    alert.messageText = "Remove the Bluetooth pairing as well?"
    alert.informativeText = """
      macOS keeps its own pairing with the ring, and no app is permitted to \
      remove one. Until you do, the ring stays bonded to this Mac — which matters \
      if you want to use it with a phone, or if pairing here has been failing and \
      you want a genuinely clean start.

      In System Settings › Bluetooth, find the ring in the device list, click the \
      ⓘ button beside it, then Forget This Device.
      """
    alert.addButton(withTitle: "Open Bluetooth Settings")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    openBluetoothSettings()
  }

  /// The recordings folder as the menu shows it: tilde-abbreviated, and trimmed
  /// from the left so the folder name itself always survives.
  private var recordingsFolderLabel: String {
    guard let url = settings.recordingsDirectory else { return "Recordings Folder" }
    return MenuContent.shorten((url.path as NSString).abbreviatingWithTildeInPath,
                               limit: 40)
  }

  /// Trims a long value to something a menu can show without stretching.
  static func shorten(_ text: String, limit: Int = 32) -> String {
    guard text.count > limit else { return text }
    return "…" + text.suffix(limit - 1)
  }

  /// A menubar-only app is not frontmost, so an opened window would appear behind
  /// whatever the user was doing.
  ///
  /// Deferred a runloop turn because `openWindow` is not synchronous: activating
  /// an accessory app that has no window on screen yet gives it nothing to bring
  /// forward, and macOS activates the next app instead -- usually Finder.
  private func activate() {
    DispatchQueue.main.async {
      guard NSApplication.shared.windows.contains(where: { $0.isVisible }) else { return }
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  /// Opens the recordings folder, creating it if the first recording has not
  /// arrived yet -- otherwise this does nothing at all on a fresh install and
  /// looks broken.
  private func openRecordingsFolder() {
    guard let url = settings.recordingsDirectory else { return }
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      NSWorkspace.shared.open(url)
      settings.lastError = nil
    } catch {
      settings.lastError = "Could not create the recordings folder"
      coordinator.note(settingsError: "creating \(url.path): \(error)")
    }
  }

  /// A ring already bonded to a phone, or a stale bond here, is fixed in System
  /// Settings -- there is no API to drop a bond.
  private func openBluetoothSettings() {
    guard let url = URL(string:
      "x-apple.systempreferences:com.apple.Bluetooth-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
  }
}
