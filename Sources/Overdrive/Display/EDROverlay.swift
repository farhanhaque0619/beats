import AppKit
import Metal
import MetalKit
import QuartzCore

/// Keeps a display in EDR (HDR) mode by showing one tiny, extended-range pixel in a corner,
/// where the screen's rounded edge hides it. While any EDR content is on screen, the panel
/// opens up its HDR headroom, which the gamma boost then uses for everyday content.
@MainActor
final class EDROverlay: NSObject, MTKViewDelegate {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()

    var isAvailable: Bool { device != nil }

    /// Shows the overlay on exactly these screens with an EDR value above 1.
    func show(on screens: [(id: CGDirectDisplayID, screen: NSScreen)], value: Double) {
        let wanted = Set(screens.map(\.id))
        for (id, window) in windows where !wanted.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
        }
        guard let device else { return }
        for (id, screen) in screens {
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - 2, width: 2, height: 2)
            let window = windows[id] ?? makeWindow(device: device)
            window.setFrame(frame, display: false)
            if let view = window.contentView as? MTKView {
                view.clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1)
                view.needsDisplay = true
            }
            window.orderFrontRegardless()
            windows[id] = window
        }
    }

    func hideAll() {
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
    }

    private func makeWindow(device: MTLDevice) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), device: device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.delegate = self
        window.contentView = view
        return window
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue?.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
