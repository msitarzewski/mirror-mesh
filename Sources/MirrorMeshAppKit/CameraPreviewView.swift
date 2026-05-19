import SwiftUI
import AppKit
import Metal
import MetalKit
import CoreVideo
import MirrorMeshCore

/// Camera preview backed by an `MTKView`. Subscribes to `PipelineViewModel.latestFrame` and
/// blits the underlying `CVPixelBuffer` to the view's drawable via `CVMetalTextureCache` (zero copy).
/// Falls back to a colored placeholder when no frame is available or Metal is unavailable (CI).
public struct CameraPreviewView: View {
    @ObservedObject var viewModel: PipelineViewModel

    public init(viewModel: PipelineViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            // Why: keep a placeholder behind the Metal view so CI / missing-GPU hosts still show
            // something legible while the renderer hasn't produced a frame yet.
            placeholder
            MetalPreviewRepresentable(latestFrame: viewModel.latestFrame)
                .opacity(viewModel.latestFrame == nil ? 0 : 1)
                .animation(.easeIn(duration: 0.15), value: viewModel.latestFrame?.frameID.value)
            VStack {
                Spacer()
                HStack {
                    overlayLabel
                    Spacer()
                }
                .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [.indigo.opacity(0.85), .purple.opacity(0.6)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            VStack(spacing: 6) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                Text(viewModel.running ? "warming up…" : "no source")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.95))
                Text(viewModel.running
                     ? "synthetic preview starting"
                     : "press Start Session for a real consent-gated capture")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        )
    }

    private var overlayLabel: some View {
        HStack(spacing: 8) {
            // Why: distinguish preview (auto-loop) from real session in the corner badge so
            // viewers know whether they're looking at a recording-grade artifact or a demo loop.
            if viewModel.isPreview {
                Text("PREVIEW")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
            } else if viewModel.running {
                Text("SESSION")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
            }
            Group {
                if let frame = viewModel.latestFrame {
                    Text("frame \(frame.frameID.value) — \(frame.width)x\(frame.height)")
                } else if viewModel.running {
                    Text("warming up…")
                } else {
                    Text("idle — press Start Session")
                }
            }
            .foregroundStyle(.white)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - MTKView bridge

/// SwiftUI bridge around `MTKView`. The view holds a coordinator that owns the
/// `CVMetalTextureCache` and renders the latest pixel buffer on each `draw`.
private struct MetalPreviewRepresentable: NSViewRepresentable {
    let latestFrame: RenderedFrame?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        // Why: in headless/CI we can't get a Metal device; fall back to a plain NSView so the
        // SwiftUI tree still compiles + lays out. Higher up we keep the placeholder visible.
        guard let device = MTLCreateSystemDefaultDevice() else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.black.cgColor
            return v
        }
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.layer?.isOpaque = true
        context.coordinator.attach(view: view, device: device)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let mtk = nsView as? MTKView else { return }
        context.coordinator.update(frame: latestFrame, view: mtk)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var queue: MTLCommandQueue?
        private var cache: CVMetalTextureCache?
        private var currentFrame: RenderedFrame?

        func attach(view: MTKView, device: MTLDevice) {
            self.device = device
            self.queue = device.makeCommandQueue()
            var cacheOut: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cacheOut)
            self.cache = cacheOut
        }

        func update(frame: RenderedFrame?, view: MTKView) {
            // Why: avoid redundant redraws when SwiftUI re-renders for unrelated state changes.
            if let frame, currentFrame?.frameID != frame.frameID {
                currentFrame = frame
                view.setNeedsDisplay(view.bounds)
            } else if frame == nil {
                currentFrame = nil
            }
        }

        // MARK: MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard
                let queue,
                let cache,
                let frame = currentFrame,
                let drawable = view.currentDrawable,
                let cb = queue.makeCommandBuffer()
            else { return }

            let pb = frame.pixelBuffer
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            var cvTex: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pb, nil,
                .bgra8Unorm, w, h, 0, &cvTex
            )
            guard status == kCVReturnSuccess,
                  let cv = cvTex,
                  let srcTex = CVMetalTextureGetTexture(cv),
                  let blit = cb.makeBlitCommandEncoder()
            else { return }

            // Why: copy the renderer's BGRA frame into the drawable; sizes may differ if the
            // window has been resized, so clamp to the smaller extent on each axis.
            let dst = drawable.texture
            let copyW = min(w, dst.width)
            let copyH = min(h, dst.height)
            blit.copy(
                from: srcTex,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                to: dst,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            cb.present(drawable)
            cb.commit()
            _ = cv  // hold the CVMetalTexture until the GPU is done
        }
    }
}
