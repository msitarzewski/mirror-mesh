import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var model: String
    public var chip: String
    public var memory_gb: Int
    public var os_version: String

    public init(model: String, chip: String, memory_gb: Int, os_version: String) {
        self.model = model
        self.chip = chip
        self.memory_gb = memory_gb
        self.os_version = os_version
    }

    public static func current() -> DeviceInfo {
        DeviceInfo(
            model: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            memory_gb: physicalMemoryGB(),
            os_version: osVersionString()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func physicalMemoryGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return Int((Double(bytes) / 1_073_741_824).rounded())
    }

    private static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
