import AppKit
import SwiftUI

// MARK: - Screen resolution

/// Reports the `NSScreen` that hosts this view's window back through a binding.
///
/// Barik Enhanced places one full-screen `NSPanel` per display, positioned at that
/// display's origin (see `AppDelegate`). A widget therefore needs to know *which*
/// screen its panel is on before it can reason about that screen's notch or its
/// reserved system-status area. This mirrors the `CustomBlurView` `NSViewRepresentable`
/// style: a tiny probe view that reads `window?.screen` once it's attached, and
/// re-reads it whenever the display arrangement changes.
struct ScreenReader: NSViewRepresentable {
    @Binding var screen: NSScreen?

    func makeNSView(context: Context) -> NSView {
        ProbeView { resolved in screen = resolved }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ProbeView: NSView {
        private let onResolve: (NSScreen?) -> Void
        private var observer: NSObjectProtocol?

        init(onResolve: @escaping (NSScreen?) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in self?.report() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        /// Resolving happens off the SwiftUI update pass (async) so we never mutate
        /// binding state during layout. After a screen-parameter change `NSScreen`
        /// instances are rebuilt, so re-reporting hands SwiftUI a fresh object and
        /// dependent geometry recomputes.
        private func report() {
            let resolved = window?.screen
            DispatchQueue.main.async { [weak self] in self?.onResolve(resolved) }
        }
    }
}

// MARK: - Notch geometry

extension NSScreen {
    /// True when this display has a camera-housing notch.
    var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    /// Distance from this screen's leading (left) edge to the notch's left edge,
    /// or `nil` when there is no notch.
    ///
    /// `auxiliaryTopLeftArea` is the menu-bar-height region to the *left* of the
    /// notch, expressed in the same coordinate space as `frame`. Its right edge is
    /// the notch's left edge; subtracting `frame.minX` makes the value relative to
    /// this screen's own leading edge — the same reference a widget's window-local
    /// `.global` `minX` uses (each panel sits at the screen origin).
    var notchLeadingInset: CGFloat? {
        guard hasNotch, let leftArea = auxiliaryTopLeftArea else { return nil }
        return leftArea.maxX - frame.minX
    }

    /// Distance from this screen's leading (left) edge to the notch's *right* edge,
    /// or `nil` when there is no notch. Mirrors `notchLeadingInset`: the left edge
    /// of `auxiliaryTopRightArea` (the region to the *right* of the notch) is the
    /// notch's right edge. Used by trailing (right-section) widgets, which grow
    /// leftward and must stop at the notch's right edge.
    var notchTrailingInset: CGFloat? {
        guard hasNotch, let rightArea = auxiliaryTopRightArea else { return nil }
        return rightArea.minX - frame.minX
    }
}
