import AppKit
import SwiftUI

/// Offscreen renderer for the panel, used while iterating on the UI.
///
/// `display++ --render <path>` builds the real panel view and writes a PNG.
/// This exists because checking the layout by launching the app and taking a
/// screenshot needs Screen Recording permission, while `ImageRenderer` needs
/// nothing — so the visual work does not stall on a TCC prompt.
///
/// Glass is swapped for an equivalent material (see `RenderMode`); every other
/// pixel is the same code path the app runs.
@MainActor
enum RenderPreview {
    static func run(path: String) {
        RenderMode.isOffscreen = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let model = PanelModel()
        model.start()

        let view = AppMenuView(model: model, onClose: {}, onSettings: {}, onQuit: {})
            .frame(width: PanelMetrics.panelWidth)
            .padding(10)
            .background(PreviewBackdrop())

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.isOpaque = true

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render: failed\n".utf8))
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("rendered \(path)  \(Int(image.size.width))x\(Int(image.size.height))  devices=\(model.devices.count)")
    }
}

/// Warm-to-cool gradient standing in for a wallpaper, so the translucent blocks
/// have something to sit against in the preview.
struct PreviewBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.74, green: 0.64, blue: 0.55),
                Color(red: 0.44, green: 0.47, blue: 0.58)
            ],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
    }
}
