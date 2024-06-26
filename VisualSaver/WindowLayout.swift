import AppKit
import SwiftUI

/// Keeps the window inside the screen.
///
/// SwiftUI sizes a window from its content's ideal/minimum size; with a detailed
/// pane that can exceed the display, parts of the UI would end up off-screen.
/// This configurator runs once the window exists, lowers the content minimum
/// size and clamps the window to the visible frame of the *smallest* attached
/// display, so the whole UI stays visible no matter which screen is used.
struct WindowLayoutConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.configure(view.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var didClamp = false

        func configure(_ window: NSWindow?) {
            guard let window, !didClamp else { return }
            didClamp = true

            window.contentMinSize = NSSize(width: 900, height: 560)

            let screens = NSScreen.screens
            let smallest = screens.map(\.visibleFrame).reduce(nil as CGRect?, { partial, frame in
                guard let partial else { return frame }
                return frame.width < partial.width || frame.height < partial.height ? frame : partial
            })
            guard let visible = smallest else { return }

            let margin: CGFloat = 24
            let maxWidth = max(900, visible.width - margin)
            let maxHeight = max(560, visible.height - margin)

            var frame = window.frame
            let tooBig = frame.width > maxWidth || frame.height > maxHeight
            if tooBig {
                frame.size.width = min(frame.width, maxWidth)
                frame.size.height = min(frame.height, maxHeight)
            }

            // Also re-centre if the window ended up outside every screen.
            let insideSomeScreen = screens.contains { $0.visibleFrame.contains(frame) }
            guard tooBig || !insideSomeScreen else { return }

            let target = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? visible
            frame.origin.x = target.minX + (target.width - frame.width) / 2
            frame.origin.y = target.minY + (target.height - frame.height) / 2
            window.setFrame(frame, display: true)
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}
