import CoreImage
import CoreVideo
import MetalKit
import SwiftUI

final class FrameStore: ObservableObject {
    @Published private(set) var latest: CVPixelBuffer?

    func publish(_ pixelBuffer: CVPixelBuffer) {
        DispatchQueue.main.async { [weak self] in self?.latest = pixelBuffer }
    }
}

struct PixelBufferSurface: UIViewRepresentable {
    @ObservedObject var frameStore: FrameStore

    func makeUIView(context: Context) -> PixelBufferMTKView {
        PixelBufferMTKView()
    }

    func updateUIView(_ view: PixelBufferMTKView, context: Context) {
        if let latest = frameStore.latest { view.display(latest) }
    }
}

final class PixelBufferMTKView: MTKView, MTKViewDelegate {
    private let ciContext: CIContext
    private var pixelBuffer: CVPixelBuffer?

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true
        colorPixelFormat = .bgra8Unorm
        delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
        draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pixelBuffer, let drawable = currentDrawable else { return }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let targetWidth = CGFloat(drawable.texture.width)
        let targetHeight = CGFloat(drawable.texture.height)
        let scale = min(targetWidth / source.extent.width, targetHeight / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translated = scaled.transformed(by: CGAffineTransform(
            translationX: (targetWidth - scaled.extent.width) / 2,
            y: (targetHeight - scaled.extent.height) / 2
        ))
        ciContext.render(
            translated,
            to: drawable.texture,
            commandBuffer: nil,
            bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        drawable.present()
    }
}

