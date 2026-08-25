import Combine
import Foundation

/// A clock that nothing else observes.
///
/// The menu shows relative times — "8 minutes ago" — computed when the view
/// renders. Nothing publishes while the app is idly scanning, so those strings
/// freeze at whatever they said when the menu was last built.
///
/// Ticking `RingCoordinator` instead would republish to every view observing it,
/// and that is the mechanism behind an earlier bug: the menu-bar icon used to read
/// coordinator state inside the **App body**, so each publish re-evaluated the
/// whole `Scene` graph including both `Window` scenes — and a menu-bar-only app
/// churning windows hands activation to Finder. Keeping the clock in its own
/// object bounds the blast radius to the one `Text` that renders an age.
@MainActor
final class Ticker: ObservableObject {
  /// Fine for minute-resolution ages, and cheap enough not to matter.
  static let interval: TimeInterval = 5

  @Published private(set) var now = Date()
  private var timer: Timer?

  init() {
    timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) {
      [weak self] _ in
      Task { @MainActor in self?.now = Date() }
    }
  }

  deinit { timer?.invalidate() }
}
