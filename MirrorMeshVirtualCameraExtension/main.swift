// CMIO system-extension entry point.
//
// Per ADR-0013, executable Swift targets normally must not name their entry file
// `main.swift` because the implicit top-level entry conflicts with `@main`. CMIO
// extensions are exempt: they do NOT use `@main` — `CMIOExtensionProvider`
// requires the host to call `CMIOExtensionProvider.startService(provider:)` from
// a top-level statement. The file name `main.swift` is what enables those
// statements to run as the executable entry point.

import Foundation
import CoreMediaIO

// Why: providerSource is the long-lived object the OS holds onto; the extension
// process stays alive for the lifetime of any client (Zoom, QuickTime, ...) that
// has the device opened. We don't manage retain ourselves.
let providerSource = MirrorMeshVirtualCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

// startService never returns; if it ever does, fall through and the process exits.
CFRunLoopRun()
