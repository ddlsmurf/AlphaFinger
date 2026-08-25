import AppKit
import Foundation
import UserNotifications

/// User notifications, and what happens when one is clicked.
///
/// Every notification this app posts is about a file, so clicking one reveals
/// that file in Finder. A notification you cannot act on is just an interruption.
@MainActor
final class Notifier: NSObject {
  /// Carried in `userInfo` so the click handler knows what to reveal.
  /// `nonisolated` because the delegate callbacks read it off the main actor.
  nonisolated private static let pathKey = "revealPath"

  private var isAuthorised = false
  private var didAsk = false
  /// Where to say what happened. Posting used to be entirely silent, so a refused
  /// permission and a delivered notification looked identical from the log --
  /// which is no way to answer "why did nothing appear".
  var onLog: ((String) -> Void)?

  /// Asks once, lazily.
  ///
  /// Deliberately not asked at launch: a permission prompt before the app has
  /// done anything is the kind of thing people deny out of hand. The first
  /// notification is when it has earned the right to ask.
  private func authorise() async -> Bool {
    if didAsk { return isAuthorised }
    didAsk = true
    let centre = UNUserNotificationCenter.current()
    centre.delegate = self
    do {
      isAuthorised = try await centre.requestAuthorization(options: [.alert, .sound])
      if !isAuthorised {
        onLog?("notifications are not allowed for this app — nothing will appear "
               + "until it is granted in System Settings > Notifications")
      }
    } catch {
      isAuthorised = false
      onLog?("could not ask for notification permission: \(error)")
    }
    return isAuthorised
  }

  /// Posts a notification. `reveal` is shown in Finder if the user clicks it.
  ///
  /// `isRoutine` marks news that should not interrupt: the banner fades on its own
  /// and never lights up a Focus mode. It deliberately does **not** withdraw the
  /// notification afterwards. An earlier version did, six seconds after posting,
  /// and that quietly destroyed the thing it was for -- the notification is the
  /// only way to reveal a recording in Finder, and you cannot click what has been
  /// taken away. Fading is what "dismisses itself" should mean; deleting is not.
  func post(title: String, body: String, reveal: URL?, sound: Bool = false,
            isRoutine: Bool = false) {
    Task {
      guard await authorise() else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      if sound { content.sound = .default }
      // Passive keeps a routine notification from lighting the screen or
      // breaking a Focus mode; a failure is worth interrupting for.
      content.interruptionLevel = isRoutine ? .passive : .active
      if let reveal { content.userInfo = [Self.pathKey: reveal.path] }

      let identifier = UUID().uuidString
      // nil trigger means deliver immediately.
      let request = UNNotificationRequest(identifier: identifier,
                                          content: content, trigger: nil)
      do {
        try await UNUserNotificationCenter.current().add(request)
        onLog?("posted \"\(title)\"")
      } catch {
        onLog?("could not post \"\(title)\": \(error)")
      }
    }
  }
}

extension Notifier: UNUserNotificationCenterDelegate {
  /// Without this, a notification posted while the app is frontmost is swallowed.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    guard let path = info[Self.pathKey] as? String else { return }
    await MainActor.run {
      let url = URL(fileURLWithPath: path)
      if FileManager.default.fileExists(atPath: path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } else {
        // The file was moved or deleted since; showing its folder is better than
        // doing nothing at all.
        NSWorkspace.shared.open(url.deletingLastPathComponent())
      }
    }
  }
}
