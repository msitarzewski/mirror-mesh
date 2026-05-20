import SwiftUI
import AppKit
import CoreVideo
import CoreImage
import MirrorMeshCore

/// Small picture-in-picture overlay showing the raw camera capture pre-render. Used in Mirror
/// and Mask render styles so the operator's actual face is visible alongside the synthetic
/// hero view. The "this is who's actually driving" verification window.
///
/// Renders a CVPixelBuffer via an NSImageView backed by a Core Image conversion. We don't need
/// MTKView-grade throughput here — PIP frame rate matches the pipeline, not the screen.
@MainActor
public struct OperatorPIPView: View {
    @ObservedObject var viewModel: PipelineViewModel

    public init(viewModel: PipelineViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color.black
            if let frame = viewModel.latestCapturedFrame {
                PixelBufferImage(buffer: frame.pixelBuffer)
                    .id(frame.frameID.value)
            } else {
                Image(systemName: "video.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            VStack {
                Spacer()
                HStack {
                    Text("OPERATOR")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.4), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
        .help("Operator's raw camera — the actual person driving the synthetic hero view. Use this to verify the source identity.")
    }
}

/// SwiftUI bridge that renders a CVPixelBuffer as an Image via Core Image → CGImage. Not
/// zero-copy like MTKView but simpler — the PIP is small (140×105) so the overhead is fine.
private struct PixelBufferImage: NSViewRepresentable {
    let buffer: CVPixelBuffer

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleAxesIndependently
        v.imageAlignment = .alignCenter
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        // CIImage → CGImage → NSImage. Each PIP frame is its own conversion; the PIP fires
        // at pipeline cadence (~30 Hz) not screen cadence (~120 Hz), so this is fine.
        let ci = CIImage(cvPixelBuffer: buffer)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let size = NSSize(width: ci.extent.width, height: ci.extent.height)
        nsView.image = NSImage(cgImage: cg, size: size)
    }
}
