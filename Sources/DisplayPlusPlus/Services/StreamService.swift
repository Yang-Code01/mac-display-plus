import AppKit
import AVFoundation
import ScreenCaptureKit

/// Display capture into a floating picture-in-picture window.
///
/// The smallest honest version of a stream/PiP pipeline: ScreenCaptureKit captures the
/// display's own framebuffer, the sample buffers are handed to an
/// `AVSampleBufferDisplayLayer`, and that layer is the content of a floating panel. What it
/// does *not* do is compose through Metal, crop with an editor, or scale with the display's
/// own colour pipeline — a captured stream is a copy of the framebuffer, so HDR and some
/// protected content will not look right.
///
/// Permissions are the hard part: `SCShareableContent` is refused until the app has Screen
/// Recording permission, and the refusal looks exactly like "no displays". Every entry point
/// therefore reports which of the two happened instead of silently doing nothing.
final class StreamService {
    static let shared = StreamService()

    enum Failure: Error {
        case permissionDenied
        case noSuchDisplay
        case streamFailed(String)

        var message: String {
            switch self {
            case .permissionDenied:
                return L("Screen Recording permission is required. Grant it in System Settings › Privacy & Security › Screen Recording, then reopen the window.")
            case .noSuchDisplay:
                return L("That display is no longer connected.")
            case .streamFailed(let reason):
                return L("Capture failed: %@", reason)
            }
        }
    }

    /// One running capture. Kept alive by the service so the window can be closed and the
    /// stream stopped without losing track of it.
    final class Session {
        let displayID: CGDirectDisplayID
        let window: PiPWindow
        var stream: SCStream?
        /// `SCStream` holds its outputs weakly, so without this the sample handler is
        /// deallocated the moment `beginCapture` returns and no frame ever arrives
        /// (measured: window on screen, zero frames in 4 s).
        var output: StreamOutput?
        var frames: Int = 0

        init(displayID: CGDirectDisplayID, window: PiPWindow) {
            self.displayID = displayID
            self.window = window
        }
    }

    private(set) var sessions: [CGDirectDisplayID: Session] = [:]

    static var hasPermission: Bool {
        // There is no direct "is screen recording allowed" API; the honest check is whether
        // capture content can be listed at all, which is what the caller does anyway.
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Starts a PiP window for the display. `completion` reports the failure reason rather
    /// than throwing into a button closure.
    func startPiP(for displayID: CGDirectDisplayID, name: String, floating: Bool = true, completion: @escaping (Result<Void, Failure>) -> Void) {
        // Sessions and windows are main-thread state; the capture callbacks arrive elsewhere.
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.startPiP(for: displayID, name: name, floating: floating, completion: completion) }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            Self.requestPermission()
            completion(.failure(.permissionDenied))
            return
        }
        if sessions[displayID] != nil {
            sessions[displayID]?.window.show()
            completion(.success(()))
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    completion(.failure(.permissionDenied))
                    return
                }
                guard let display = content?.displays.first(where: { $0.displayID == displayID }) else {
                    completion(.failure(.noSuchDisplay))
                    return
                }
                self.beginCapture(display: display, name: name, floating: floating, completion: completion)
            }
        }
    }

    private func beginCapture(display: SCDisplay, name: String, floating: Bool, completion: @escaping (Result<Void, Failure>) -> Void) {
        let window = PiPWindow(title: name, floating: floating)
        let session = Session(displayID: display.displayID, window: window)
        sessions[display.displayID] = session

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = StreamOutput { [weak session] buffer in
            // Frames arrive on the capture queue; the layer belongs to a window on main.
            DispatchQueue.main.async {
                guard let session else { return }
                session.frames += 1
                session.window.enqueue(buffer)
            }
        }
        session.output = output
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "displaypp.stream"))
        } catch {
            sessions.removeValue(forKey: display.displayID)
            completion(.failure(.streamFailed(error.localizedDescription)))
            return
        }
        stream.startCapture { error in
            DispatchQueue.main.async {
                if let error {
                    self.sessions.removeValue(forKey: display.displayID)
                    window.close()
                    completion(.failure(.streamFailed(error.localizedDescription)))
                } else {
                    session.stream = stream
                    window.show()
                    completion(.success(()))
                }
            }
        }
    }

    func stop(_ displayID: CGDirectDisplayID) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.stop(displayID) }
            return
        }
        guard let session = sessions.removeValue(forKey: displayID) else { return }
        session.stream?.stopCapture { _ in }
        session.window.close()
    }

    func frameCount(for displayID: CGDirectDisplayID) -> Int { sessions[displayID]?.frames ?? 0 }

    func stopAll() {
        for id in sessions.keys { stop(id) }
    }
}

/// Sample-buffer sink. Separate object because `SCStreamOutput` is a protocol on a class.
final class StreamOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        handler(sampleBuffer)
    }
}

/// The floating window: a title bar, a close button and an `AVSampleBufferDisplayLayer`.
///
/// A plain `CALayer` cannot present video sample buffers; `AVSampleBufferDisplayLayer` exists
/// exactly for "here are decoded frames, show them", which is what ScreenCaptureKit hands out.
final class PiPWindow: NSPanel {
    private let displayLayer = AVSampleBufferDisplayLayer()

    init(title: String, floating: Bool = true) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .resizable, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        self.title = L("Picture in Picture — %@", title)
        isFloatingPanel = floating
        level = floating ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .black
        hasShadow = true

        let view = NSView(frame: contentRect(forFrameRect: frame))
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(displayLayer)
        contentView = view
        center()
    }

    override var canBecomeKey: Bool { true }

    /// `orderFront` is the AppKit spelling; a `show()` alias keeps the call sites readable.
    func show() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    func enqueue(_ buffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(buffer)
    }
}
