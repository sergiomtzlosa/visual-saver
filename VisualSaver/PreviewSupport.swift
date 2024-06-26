import AVFoundation
import ObjectiveC
import ScreenSaver
import SwiftUI

// MARK: - Aerial asset preview (looping video, local thumbnail or remote image)

final class LoopingPlayerView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        player.isMuted = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 180) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func load(url: URL) {
        looper?.disableLooping()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        playerLayer.player = player
        player.play()
    }

    var isPlaying: Bool { player.rate != 0 }

    func setPlaying(_ playing: Bool) {
        playing ? player.play() : player.pause()
    }

    func teardown() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.player = nil
    }
}

struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var playing: Bool

    func makeNSView(context: Context) -> LoopingPlayerView {
        let view = LoopingPlayerView()
        view.load(url: url)
        view.setPlaying(playing)
        return view
    }

    func updateNSView(_ view: LoopingPlayerView, context: Context) {
        if view.isPlaying != playing { view.setPlaying(playing) }
    }

    static func dismantleNSView(_ view: LoopingPlayerView, coordinator: ()) {
        view.teardown()
    }
}

struct AerialPreviewView: View {
    let thumbnail: URL?
    let video: URL?
    let remote: URL?
    var playing: Bool

    var body: some View {
        ZStack {
            Color.black
            if let video {
                LoopingVideoView(url: video, playing: playing)
            } else if let thumbnail, let image = NSImage(contentsOf: thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                VStack {
                    Spacer()
                    Text("Local thumbnail — video not downloaded")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(8)
                }
            } else if let remote {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: fallback("Preview image could not be downloaded")
                    default: ProgressView()
                    }
                }
            } else {
                fallback("No preview available")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private func fallback(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.white.opacity(0.7))
    }
}

// MARK: - NSView host that embeds a real ScreenSaverView

final class PreviewHost: NSView {
    private(set) var current: ScreenSaverView?
    private var guardTimer: Timer?

    /// Some screen saver plugins report (or constrain) a very large size.
    /// Reporting a small intrinsic size keeps the embedding window from
    /// growing beyond the screen — SwiftUI lays the view out from its frame.
    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 180)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
    }

    /// The embedded screen saver always fills the whole preview box, so the
    /// view can never render smaller than the box it is shown in.
    override func layout() {
        super.layout()
        if let current, current.frame != bounds {
            current.frame = bounds
        }
    }

    deinit {
        guardTimer?.invalidate()
    }

    func install(bundleURL: URL) -> String {
        tearDown()
        guard let bundle = Bundle(url: bundleURL) else {
            return "This is not a bundle that can be opened."
        }
        guard let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            let declared = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            if let declared, declared.contains("$(") || declared.contains("${") {
                return "This bundle was never built: CFBundleExecutable is still “\(declared)” and there is no executable in Contents/MacOS. Copy the built .saver out of Xcode and try again."
            }
            return "This bundle has no executable file in Contents/MacOS, so there is nothing to run."
        }
        guard bundle.load() else {
            return "The bundle's executable code could not be loaded."
        }
        guard let cls = Self.screenSaverViewClass(in: bundle) else {
            let declared = bundle.object(forInfoDictionaryKey: "NSPrincipalClass") as? String ?? "—"
            return "No ScreenSaverView subclass could be loaded from this bundle (Info.plist declares “\(declared)”)."
        }
        guard let view = cls.init(frame: bounds, isPreview: false) ?? cls.init(frame: bounds, isPreview: true) else {
            return "The screen saver view could not be created."
        }
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        addSubview(view)
        current = view
        view.startAnimation()
        startGuarding()
        return ""
    }

    /// The class named by `NSPrincipalClass`, or — for bundles whose build
    /// settings were never expanded (a stray `$(PRODUCT_NAME)` and friends) —
    /// the first ScreenSaverView subclass found in the bundle's own binary.
    static func screenSaverViewClass(in bundle: Bundle) -> ScreenSaverView.Type? {
        if let declared = bundle.principalClass as? ScreenSaverView.Type { return declared }

        var count: UInt32 = 0
        guard let classes = objc_copyClassList(&count) else { return nil }
        defer { free(unsafeBitCast(classes, to: UnsafeMutableRawPointer.self)) }
        let expected = bundle.executableURL?.resolvingSymlinksInPath().path

        for index in 0..<Int(count) {
            let candidate: AnyClass = classes[index]
            guard let image = class_getImageName(candidate) else { continue }
            let path = URL(fileURLWithPath: String(cString: image)).resolvingSymlinksInPath().path
            guard path == expected else { continue }
            if let saver = candidate as? ScreenSaverView.Type { return saver }
        }
        return nil
    }

    func tearDown() {
        guardTimer?.invalidate()
        guardTimer = nil
        current?.stopAnimation()
        current?.removeFromSuperview()
        current = nil
    }

    func toggleAnimation() {
        guard let view = current else { return }
        if view.animationTimeInterval != 0 {
            view.stopAnimation()
        } else {
            view.startAnimation()
        }
    }

    // MARK: - Containment

    /// Some plugins (for example the XScreenSaver family) move themselves or a
    /// sibling into the window's content view so that they cover the whole
    /// screen. That blows up the layout and hides the app's own controls, so
    /// while a preview is installed we periodically pull such views back into
    /// the preview box and keep the box's view at the box's size.
    private func startGuarding() {
        guardTimer?.invalidate()
        guardTimer = Timer.scheduledTimer(timeInterval: 0.7, target: self,
                                          selector: #selector(reclaimViews),
                                          userInfo: nil, repeats: true)
    }

    @objc private func reclaimViews() {
        if let window, let content = window.contentView {
            removeEscapedScreenSavers(in: content)
        }
        if let mine = current, mine.superview !== self {
            mine.removeFromSuperview()
            addSubview(mine)
            mine.frame = bounds
            mine.startAnimation()
        } else if let mine = current, mine.frame != bounds {
            mine.frame = bounds
        }
    }

    private func removeEscapedScreenSavers(in view: NSView) {
        for sub in view.subviews where !contained(inPreview: sub) {
            if let saver = sub as? ScreenSaverView {
                saver.stopAnimation()
                saver.removeFromSuperview()
                continue
            }
            removeEscapedScreenSavers(in: sub)
        }
    }

    /// True when the view is this host or one of its descendants.
    private func contained(inPreview view: NSView) -> Bool {
        var node: NSView? = view
        while let candidate = node {
            if candidate === self { return true }
            node = candidate.superview
        }
        return false
    }
}

// MARK: - Engine shared between SwiftUI and the NSView host

@MainActor
final class PreviewEngine: ObservableObject {
    @Published var status = "Select a screen saver."
    @Published var running = false
    @Published var canConfigure = false
    @Published var showNoSheetAlert = false

    var installedURL: URL?
    var sheet: NSWindow?
    weak var host: PreviewHost?

    func configure() {
        if let sheet {
            NSApp.keyWindow?.beginSheet(sheet)
        } else {
            showNoSheetAlert = true
        }
    }
}

// MARK: - SwiftUI bridge

struct PreviewRepresentable: NSViewRepresentable {
    @ObservedObject var engine: PreviewEngine
    var bundleURL: URL?

    func makeNSView(context: Context) -> PreviewHost {
        // A fresh host view is created whenever the Preview tab is shown
        // again, so force a reload of the plugin.
        engine.installedURL = nil
        return PreviewHost()
    }

    func updateNSView(_ view: PreviewHost, context: Context) {
        engine.host = view
        guard engine.installedURL != bundleURL else { return }
        engine.installedURL = bundleURL
        engine.sheet = nil

        if let url = bundleURL {
            let error = view.install(bundleURL: url)
            let loaded = view.current
            DispatchQueue.main.async {
                engine.running = loaded != nil
                engine.status = error.isEmpty
                    ? (loaded != nil ? "Running — \((url as NSURL).lastPathComponent!)" : "Bundle loaded but no view was created.")
                    : error
                engine.sheet = loaded?.configureSheet
                engine.canConfigure = engine.sheet != nil
            }
        } else {
            view.tearDown()
            DispatchQueue.main.async {
                engine.running = false
                engine.status = "Select a screen saver."
                engine.canConfigure = false
            }
        }
    }

    static func dismantleNSView(_ view: PreviewHost, coordinator: ()) {
        view.tearDown()
    }
}
