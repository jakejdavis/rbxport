import AppKit
import Observation
import SwiftUI

/// Where the main window was, how wide its side panels were, kept in the app's defaults.
///
/// React keeps the tree width, the info panel and the window frame (tauri-plugin-window-state,
/// then `fit_window` clamps it to the screen). The player/browser split (`player.height`) and the
/// deck panel (`player.layout`, the full browser being "hidden") are kept by the player model;
/// this holds the rest and the maths of fitting a saved frame to today's screen.
@MainActor @Observable
final class WindowGeometryStore {
    enum Keys {
        static let sidebarWidth = "window.sidebarWidth"
        static let infoWidth = "window.infoWidth"
        static let mainFrame = "window.mainFrame"
    }

    static let sidebarRange = 180.0...400.0
    static let infoRange = 220.0...420.0
    static let defaultSidebarWidth = 240.0
    static let defaultInfoWidth = 280.0
    /// The smallest the main window may be (the content view's own minimum).
    static let minimumWindowSize = CGSize(width: 980, height: 640)

    @ObservationIgnored let defaults: UserDefaults
    /// What the panels were on launch: the widths the split view starts at. Not observed, so a
    /// drag does not rebuild the view it is dragging.
    let initialSidebarWidth: Double
    let initialInfoWidth: Double
    @ObservationIgnored private(set) var sidebarWidth: Double
    @ObservationIgnored private(set) var infoWidth: Double

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let sidebar = Self.clamp(
            defaults.object(forKey: Keys.sidebarWidth) as? Double ?? Self.defaultSidebarWidth, Self.sidebarRange)
        let info = Self.clamp(defaults.object(forKey: Keys.infoWidth) as? Double ?? Self.defaultInfoWidth, Self.infoRange)
        initialSidebarWidth = sidebar
        initialInfoWidth = info
        sidebarWidth = sidebar
        infoWidth = info
    }

    nonisolated static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Remembers the sidebar's width (clamped); movements under a point are noise.
    func setSidebarWidth(_ width: Double) {
        // A collapsed sidebar reads as 0: that is not a width to come back to.
        guard Self.sidebarRange.lowerBound - 1 <= width, width <= Self.sidebarRange.upperBound + 1 else { return }
        let value = Self.clamp(width, Self.sidebarRange)
        guard abs(value - sidebarWidth) >= 1 else { return }
        sidebarWidth = value
        defaults.set(value, forKey: Keys.sidebarWidth)
    }

    func setInfoWidth(_ width: Double) {
        guard Self.infoRange.lowerBound - 1 <= width, width <= Self.infoRange.upperBound + 1 else { return }
        let value = Self.clamp(width, Self.infoRange)
        guard abs(value - infoWidth) >= 1 else { return }
        infoWidth = value
        defaults.set(value, forKey: Keys.infoWidth)
    }

    // MARK: The window's frame

    /// The last frame of the main window, if one was kept.
    var savedFrame: CGRect? {
        guard let text = defaults.string(forKey: Keys.mainFrame) else { return nil }
        let rect = NSRectFromString(text)
        guard rect.width.isFinite, rect.height.isFinite, rect.width >= 100, rect.height >= 100 else { return nil }
        return rect
    }

    func saveFrame(_ frame: CGRect) {
        guard frame.width >= 100, frame.height >= 100 else { return }
        defaults.set(NSStringFromRect(frame), forKey: Keys.mainFrame)
    }

    /// The saved frame made to fit `visible` (the screen less the menu bar and Dock): shrunk
    /// first, then moved inside. Nil when nothing was saved.
    func restoredFrame(in visible: CGRect, minSize: CGSize = minimumWindowSize) -> CGRect? {
        savedFrame.map { Self.fit($0, in: visible, minSize: minSize) }
    }

    /// `windowfit.rs`: shrink to the work area (but not under the minimum), then clamp the position.
    nonisolated static func fit(_ frame: CGRect, in visible: CGRect, minSize: CGSize) -> CGRect {
        var rect = frame
        rect.size.width = min(rect.width, max(visible.width, minSize.width))
        rect.size.height = min(rect.height, max(visible.height, minSize.height))
        rect.size.width = max(rect.width, min(minSize.width, visible.width))
        rect.size.height = max(rect.height, min(minSize.height, visible.height))
        rect.origin.x = min(max(rect.minX, visible.minX), max(visible.maxX - rect.width, visible.minX))
        rect.origin.y = min(max(rect.minY, visible.minY), max(visible.maxY - rect.height, visible.minY))
        return rect
    }
}

// MARK: - The window

/// Restores the main window's frame once, and keeps it as it moves and resizes (after it has
/// settled, throttled), as React's window-state does.
@MainActor
final class MainWindowGeometry {
    let store: WindowGeometryStore
    /// Nothing is saved while the window is still taking its first shape.
    static let settle: Duration = .seconds(2)
    static let throttle: Duration = .milliseconds(300)
    private weak var window: NSWindow?
    private var settled = false
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(store: WindowGeometryStore) { self.store = store }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        if let screen = window.screen ?? NSScreen.main, let frame = store.restoredFrame(in: screen.visibleFrame) {
            window.setFrame(frame, display: true)
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settle)
            self?.settled = true
        }
    }

    private func changed() {
        guard settled, pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.throttle)
            guard let self else { return }
            pending = nil
            if let window, !window.styleMask.contains(.fullScreen), window.isVisible { store.saveFrame(window.frame) }
        }
    }

}

/// Hands the hosting `NSWindow` to `onWindow` once the view is in one.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let onWindow else { return }
            // After SwiftUI has sized the window, not during.
            DispatchQueue.main.async { MainActor.assumeIsolated { onWindow(window) } }
        }
    }
}
