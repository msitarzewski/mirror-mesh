import SwiftUI
import AppKit
import Metal
import MetalKit
import CoreVideo
import MirrorMeshCore

/// Camera preview backed by an `MTKView`. Subscribes to `PipelineViewModel.latestFrame` and
/// blits the underlying `CVPixelBuffer` to the view's drawable. The drawable size tracks the
/// source so `CAMetalLayer.contentsGravity = .resizeAspect` produces a proper letterbox/pillarbox.
@MainActor
public struct CameraPreviewView: View {
    @ObservedObject var viewModel: PipelineViewModel

    public init(viewModel: PipelineViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            // Black "stage" behind the aspect-fit preview. Keeps the letterbox edges clean.
            Color.black
            placeholder
                .opacity(viewModel.latestFrame == nil ? 1 : 0)
            MetalPreviewRepresentable(latestFrame: viewModel.latestFrame)
                .opacity(viewModel.latestFrame == nil ? 0 : 1)
                .animation(.easeIn(duration: 0.2), value: viewModel.latestFrame?.frameID.value)
            VStack {
                Spacer()
                HStack {
                    overlayBadge
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(.sRGB, red: 0.18, green: 0.10, blue: 0.36),
                     Color(.sRGB, red: 0.38, green: 0.12, blue: 0.42)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            VStack(spacing: 10) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 42, weight: .thin))
                    .foregroundStyle(.white.opacity(0.85))
                Text(viewModel.running ? "Warming up…" : "No source")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.95))
                Text(viewModel.running
                     ? "Synthetic preview starting"
                     : "Press Start Session for a real consent-gated capture")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        )
    }

    private var overlayBadge: some View {
        HStack(spacing: 8) {
            if viewModel.isPreview {
                Text("PREVIEW")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
            } else if viewModel.running {
                Text("SESSION")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
            }
            Group {
                if let frame = viewModel.latestFrame {
                    Text("frame \(frame.frameID.value) — \(frame.width)×\(frame.height)")
                } else if viewModel.running {
                    Text("warming up…")
                } else {
                    Text("idle")
                }
            }
            .foregroundStyle(.white)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }
}

// MARK: - MTKView bridge

/// SwiftUI bridge around `MTKView`. The view holds a coordinator that owns the
/// `CVMetalTextureCache` and blits the latest pixel buffer on each `draw`. The drawable size
/// is sized to the source so CAMetalLayer.contentsGravity = .resizeAspect produces a proper
/// aspect-fit (letterbox / pillarbox) when the view's frame doesn't match.
private struct MetalPreviewRepresentable: NSViewRepresentable {
    let latestFrame: RenderedFrame?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
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
        view.autoResizeDrawable = false
        view.layer?.isOpaque = true
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.contentsGravity = .resizeAspect
            metalLayer.backgroundColor = NSColor.black.cgColor
        }
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
            if let frame, currentFrame?.frameID != frame.frameID {
                currentFrame = frame
                let desired = CGSize(width: frame.width, height: frame.height)
                if view.drawableSize != desired { view.drawableSize = desired }
                view.setNeedsDisplay(view.bounds)
            } else if frame == nil {
                currentFrame = nil
            }
        }

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

            let dst = drawable.texture
            // Drawable is sized to (w, h) by update(), so a 1:1 blit fills it. CAMetalLayer
            // then scales the drawable to the view bounds with aspect-fit.
            blit.copy(
                from: srcTex,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: w, height: h, depth: 1),
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
