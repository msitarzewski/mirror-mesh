import Foundation
import CoreMediaIO

/// Owns the single MirrorMesh CMIO device and its one video stream.
///
/// The OS instantiates a `CMIOExtensionProvider` per extension process and discovers
/// our device through `availableProperties` + `device(forStreamingDevice:)`. We never
/// allocate a second device — Zoom/QuickTime/FaceTime all share the same instance.
final class MirrorMeshVirtualCameraProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: MirrorMeshVirtualCameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        self.provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        self.deviceSource = MirrorMeshVirtualCameraDeviceSource(
            localizedName: "MirrorMesh"
        )
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            // Why: if `addDevice` fails the extension is non-functional — log and
            // continue so the OS can surface the error rather than crashing.
            NSLog("MirrorMesh: addDevice failed: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        // No-op: clients are tracked per-stream, not per-provider.
    }

    func disconnect(from client: CMIOExtensionClient) {
        // No-op.
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "MirrorMesh" }
        if properties.contains(.providerName) { p.name = "MirrorMesh Virtual Camera" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // Read-only; nothing to set.
    }
}

/// One CMIO device with one stream, exposing the "MirrorMesh" entry in the OS camera list.
final class MirrorMeshVirtualCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: MirrorMeshVirtualCameraStreamSource!

    // Fixed default format; matches the pipeline's default 640x360 @ 30 fps.
    private let width = 640
    private let height = 360
    private let frameRate = 30

    init(localizedName: String) {
        super.init()
        // Why: deviceID is a per-install UUID so the OS treats this device as stable across launches.
        let deviceID = UUID()
        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: nil,
            source: self
        )

        let format = CMIOExtensionStreamFormat(
            formatDescription: makeFormatDescription(width: width, height: height)!,
            maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            validFrameDurations: nil
        )

        self.streamSource = MirrorMeshVirtualCameraStreamSource(
            localizedName: "\(localizedName) Stream",
            streamID: UUID(),
            streamFormat: format,
            device: device
        )

        do {
            try device.addStream(streamSource.stream)
        } catch {
            NSLog("MirrorMesh: addStream failed: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        // kIOAudioDeviceTransportTypeVirtual / "virt" — best fit for a software camera.
        if properties.contains(.deviceTransportType) {
            p.setPropertyState(CMIOExtensionPropertyState(value: 1937339512 as NSNumber),
                               forProperty: .deviceTransportType)
        }
        if properties.contains(.deviceModel) { p.model = "MirrorMesh Virtual Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // Read-only.
    }

    private func makeFormatDescription(width: Int, height: Int) -> CMFormatDescription? {
        var fmt: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        return status == noErr ? fmt : nil
    }
}
