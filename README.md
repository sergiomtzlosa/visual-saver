# VisualSaver

VisualSaver is a macOS (SwiftUI) utility that shows **every screen saver this Mac
knows about** — classic `.saver` plugins, the built-in ExtensionKit providers and
the individual Aerial videos — together with their **configuration preferences**.

## What it lists (grouped in the sidebar)

| Group | Source | Count on this Mac |
|---|---|---|
| **Screen savers — .saver plugins** | `/System`, `/Library`, `~/Library/Screen Savers`, app-embedded | 298 |
| **Built-in screen saver providers** | `*.appex` with the `com.apple.wallpaper` extension point in `/System/Library/ExtensionKit/Extensions` | 11 (Aerial, Dynamic Desktop, Gradients, Pictures, Legacy, Macintosh, Monterey, Sequoia, Sonoma, Ventura, Neptune One) |
| **Aerial videos** | `~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json` | 164 assets with localised names |

Facts shown per item:
- Plugin: bundle id, version, principal class, real recursive size, file tree, Info.plist.
- Provider: extension point, version, size, Info.plist, container preferences.
- Aerial asset: localised name ("Golden Gate Sunset"), category ("Landscape · Golden Gate"),
  shot id, asset id, whether the 4K video is downloaded, cached thumbnail, manifest metadata.

The item currently configured in System Settings is marked **Active**
(read from the wallpaper store's `Idle` choice, falling back to the legacy
`com.apple.screensaver` `moduleDict`).

## Preview

- **Plugins** load their principal class (`ScreenSaverView`) into the app and run
  it, with Start/Stop and the saver's own **Configure** sheet.
- **Aerial videos** play the downloaded 4K video on loop (`AVQueuePlayer` +
  `AVPlayerLooper`); if it is not downloaded the cached thumbnail is shown.
- **Providers** are XPC extensions, so they cannot be embedded — the app explains
  this and shows their metadata and preferences instead.

The preview box is a 16:9 area that grows with the window and the embedded saver
always fills it exactly. Some plugins (the XScreenSaver family) try to escape a
preview box and cover the whole window; the app detects that and pulls them back,
so the rest of the UI can never be hidden by a running saver.

## Custom screen savers

**Add screen saver…** (in the panel footer or the detail toolbar) opens a file
chooser and loads `.saver` bundles from anywhere on the Mac — for example a
download that is not installed yet. You can pick several bundles at once, or a
folder that contains them. They appear in the sidebar under *Added by you* with
an **Added** badge, are previewed and inspected exactly like installed savers,
and are removed again with *Remove from list* (the bundle itself is not deleted).
The chosen locations are remembered between launches; entries whose file has
disappeared are dropped automatically.

## Removing items from the list

Every row has a right-click menu with **Remove from list** (also on the selected
item in the detail toolbar, or with the ⌫ key). Removed items disappear from all
sections and stay gone after a relaunch; a **Restore N hidden** button in the
toolbar brings them back. Nothing is deleted from disk — for a screen saver you
really want to get rid of, use *Reveal in Finder* and delete the bundle there.

## Screen savers that cannot run

A few third-party bundles are copied out of a project folder before they are
built, so `Contents/MacOS` is empty and `Info.plist` still contains raw Xcode
build settings (`$(PRODUCT_NAME)`, `$(EXECUTABLE_NAME)`). Those can never run —
macOS cannot use them as a screen saver either. VisualSaver:

- shows the real file name instead of `$(PRODUCT_NAME)` and marks the row
  **Cannot run** with a warning icon,
- explains exactly what is wrong and offers *Show it in the Finder* / *Remove
  from list* instead of a black preview box (their Bundle, Info.plist and
  Preferences tabs still work),
- and, for bundles whose `NSPrincipalClass` does not resolve but which *do*
  contain code, loads the first `ScreenSaverView` subclass found in the binary.

## Panel

The left panel can be hidden and shown with the button at its top or in the
detail toolbar (**⌥⌘S**), and its width can be dragged with the divider between
the panel and the detail view (double-click the divider to reset it to 360 pt).

## Preferences

Everything is read-only and read from the real stores:

- `~/Library/Preferences/<bundleID>.plist`
- `~/Library/Preferences/ByHost/<bundleID>.<host-id>.plist`
- `~/Library/Containers/<extension-id>/Data/Library/Preferences/` (providers)
- **Wallpaper store** `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`,
  with the nested `Configuration` / `EncodedOptionValues` binary plists decoded —
  this is where macOS 14+ keeps the screen saver ("Idle") choice per space and display
- Legacy engine settings `com.apple.screensaver` (plain and per-host)

## Building

Open `VisualSaver.xcodeproj` in Xcode (or run
`xcodebuild -scheme VisualSaver build`) and press ▶︎.

## Notes / limitations

- The app is **unsandboxed**, which is required to load third-party `.saver` plugins.
- On launch the window is clamped to the visible frame of the *smallest* attached
  display, so sidebar and detail pane always fit on screen; the panes scroll and
  the preview box shrinks with the window instead of clipping.
- Some third-party savers crash or draw nothing when hosted outside System Settings;
  the status line under the preview reports failures.
- Savers that manage the mouse pointer themselves (the XScreenSaver family hides
  and shows the cursor while they animate) no longer make the pointer flicker:
  those cursor-hiding calls are neutralised for the app, while normal cursor
  behaviour is untouched.
- Providers cannot be previewed; Aerial names require the aerial manifest that
  System Settings itself uses (present after the first Aerial selection).
- Deprecated `slidesaver`/web-plugin savers are not supported.


