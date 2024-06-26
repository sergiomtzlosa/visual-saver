import AppKit
import ObjectiveC

/// Screen saver previews are full-screen savers running inside a window. Savers
/// of the XScreenSaver family (and others) hide and show the mouse pointer while
/// they animate, exactly as they would on the real desktop
/// (`NSCursor.hide()`, `NSCursor.unhide()`, `setHiddenUntilMouseMoves:`, and the
/// private `setHides:`/`setHidesOthers:` helpers). Inside a window that makes the
/// pointer flicker or disappear while the preview runs.
///
/// The app itself never wants a hidden pointer, so those calls are neutralised
/// once at launch. Everything else about cursors — reading, setting, pushing and
/// popping — keeps working normally.
enum CursorGuard {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        exchangeClassMethod("hide", with: "guard_ignoreHide")
        exchangeClassMethod("unhide", with: "guard_ignoreUnhide")
        exchangeClassMethod("setHiddenUntilMouseMoves:", with: "guard_ignoreFlag:")
        exchangeClassMethod("setHides:", with: "guard_ignoreFlag:")
        exchangeClassMethod("setHidesOthers:", with: "guard_ignoreFlag:")
        exchangeInstanceMethod("hide", with: "guard_ignoreInstanceHide")
        exchangeInstanceMethod("unhide", with: "guard_ignoreInstanceUnhide")
    }

    private static func exchangeClassMethod(_ original: String, with replacement: String) {
        guard let originalMethod = class_getClassMethod(NSCursor.self, Selector(original)),
              let replacementMethod = class_getClassMethod(NSCursor.self, Selector(replacement)) else {
            return
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    private static func exchangeInstanceMethod(_ original: String, with replacement: String) {
        guard let originalMethod = class_getInstanceMethod(NSCursor.self, Selector(original)),
              let replacementMethod = class_getInstanceMethod(NSCursor.self, Selector(replacement)) else {
            return
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

extension NSCursor {
    @objc class func guard_ignoreHide() {}
    @objc class func guard_ignoreUnhide() {}
    @objc class func guard_ignoreFlag(_ flag: Bool) {}
    @objc func guard_ignoreInstanceHide() {}
    @objc func guard_ignoreInstanceUnhide() {}
}
