import Foundation

/// Module marker. The virtual-camera subsystem owns the XPC channel between the
/// main app (frame producer) and the CMIO system extension (camera device).
public enum MirrorMeshVirtualCamera {
    public static let moduleName = "MirrorMeshVirtualCamera"

    /// Mach service name shared by `Info.plist` (`CMIOExtensionMachServiceName`) and
    /// the XPC listener inside the extension. Keep these literals in lock-step.
    public static let machServiceName = "ai.mirrormesh.VirtualCamera"

    /// Bundle ID of the system extension target. `OSSystemExtensionRequest` needs this
    /// to find the embedded extension inside the host app's `Contents/Library/SystemExtensions`.
    public static let extensionBundleIdentifier = "ai.mirrormesh.VirtualCameraExtension"
}
