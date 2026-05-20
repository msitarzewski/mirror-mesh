#!/usr/bin/env swift
// Generates MirrorMesh.app's iconset programmatically. Run from repo root:
//
//   swift bench/scripts/generate_app_icon.swift
//
// Writes PNGs into MirrorMesh/Assets.xcassets/AppIcon.appiconset/.
// Idempotent — re-run after changing the design below to refresh all sizes.
//
// v0.6.0 "Identity" refresh — mesh motif. The icon now reads as:
//   • Stylized 3D head silhouette (the puppet, the subject of a ConsentedIdentity)
//   • Faceted wireframe overlay (the live face-mesh — the technical thesis)
//   • Watermark check badge bottom-right (the trust thesis)
// Pure CoreGraphics. No asset designer required.

import Foundation
import AppKit
import CoreGraphics

let outputDir = URL(fileURLWithPath: "MirrorMesh/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

struct IconVariant {
    let size: Int        // rendered pixel size
    let filename: String
    let designSize: Int  // logical size (for Contents.json)
    let scale: Int       // @1x = 1, @2x = 2
}
let variants: [IconVariant] = [
    IconVariant(size: 16,   filename: "icon_16x16.png",       designSize: 16,   scale: 1),
    IconVariant(size: 32,   filename: "icon_16x16@2x.png",    designSize: 16,   scale: 2),
    IconVariant(size: 32,   filename: "icon_32x32.png",       designSize: 32,   scale: 1),
    IconVariant(size: 64,   filename: "icon_32x32@2x.png",    designSize: 32,   scale: 2),
    IconVariant(size: 128,  filename: "icon_128x128.png",     designSize: 128,  scale: 1),
    IconVariant(size: 256,  filename: "icon_128x128@2x.png",  designSize: 128,  scale: 2),
    IconVariant(size: 256,  filename: "icon_256x256.png",     designSize: 256,  scale: 1),
    IconVariant(size: 512,  filename: "icon_256x256@2x.png",  designSize: 256,  scale: 2),
    IconVariant(size: 512,  filename: "icon_512x512.png",     designSize: 512,  scale: 1),
    IconVariant(size: 1024, filename: "icon_512x512@2x.png",  designSize: 512,  scale: 2),
]

// MARK: - Mesh vertex layout
// A stylized face profile — 22 anchor points around a 3/4 view. The list is normalized
// to a unit square (origin top-left, x right, y down) so we can scale it to any icon size.
// These coordinates trace a head silhouette and an interior triangle fan covering the face plane.
struct V { let x: CGFloat; let y: CGFloat }

let silhouette: [V] = [
    V(x: 0.50, y: 0.08),   // 0  crown
    V(x: 0.64, y: 0.12),   // 1  upper temple R
    V(x: 0.74, y: 0.22),   // 2  side R
    V(x: 0.80, y: 0.36),   // 3  upper jaw R
    V(x: 0.80, y: 0.52),   // 4  cheek R
    V(x: 0.76, y: 0.66),   // 5  lower cheek R
    V(x: 0.68, y: 0.78),   // 6  jawline R
    V(x: 0.56, y: 0.88),   // 7  chin R
    V(x: 0.50, y: 0.92),   // 8  chin
    V(x: 0.44, y: 0.88),   // 9  chin L
    V(x: 0.32, y: 0.78),   // 10 jawline L
    V(x: 0.24, y: 0.66),   // 11 lower cheek L
    V(x: 0.20, y: 0.52),   // 12 cheek L
    V(x: 0.20, y: 0.36),   // 13 upper jaw L
    V(x: 0.26, y: 0.22),   // 14 side L
    V(x: 0.36, y: 0.12),   // 15 upper temple L
]
// Interior anchors — eye sockets, nose, mouth — to give the wireframe its face-ness.
let interior: [V] = [
    V(x: 0.50, y: 0.32),   // 16 brow center
    V(x: 0.38, y: 0.40),   // 17 left eye
    V(x: 0.62, y: 0.40),   // 18 right eye
    V(x: 0.50, y: 0.54),   // 19 nose tip
    V(x: 0.42, y: 0.70),   // 20 mouth L
    V(x: 0.58, y: 0.70),   // 21 mouth R
]
// Edges as index pairs — the wireframe geometry. Drawn first so the silhouette overlays.
let edges: [(Int, Int)] = [
    // Silhouette loop
    (0,1),(1,2),(2,3),(3,4),(4,5),(5,6),(6,7),(7,8),
    (8,9),(9,10),(10,11),(11,12),(12,13),(13,14),(14,15),(15,0),
    // Brow → eyes → nose triangles
    (16,17),(16,18),(17,18),
    (16,0),(16,15),(16,1),
    (17,13),(17,19),(18,3),(18,19),
    // Nose → mouth
    (19,20),(19,21),(20,21),
    // Cheek triangles
    (17,12),(17,20),(20,11),(20,10),(20,9),
    (18,4),(18,21),(21,5),(21,6),(21,7),
    // Chin
    (20,8),(21,8),
]

// MARK: - Renderer

func render(size: Int) -> Data? {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: bitmapInfo
    ) else { return nil }

    // Squircle background (macOS Tahoe icon shape).
    let radius = s * 0.225
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // v0.6.0 brand gradient: deep indigo → magenta → soft amber. Reads as "identity at dusk."
    let colors = [
        CGColor(srgbRed: 0.08, green: 0.05, blue: 0.28, alpha: 1.0),
        CGColor(srgbRed: 0.28, green: 0.10, blue: 0.46, alpha: 1.0),
        CGColor(srgbRed: 0.58, green: 0.16, blue: 0.42, alpha: 1.0),
        CGColor(srgbRed: 0.82, green: 0.34, blue: 0.36, alpha: 1.0),
    ]
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: colors as CFArray,
        locations: [0.0, 0.45, 0.78, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )

    // Soft radial highlight upper-left for "lit subject" feel.
    let highlight = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.22),
            CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: s * 0.30, y: s * 0.78),
        startRadius: 0,
        endCenter: CGPoint(x: s * 0.30, y: s * 0.78),
        endRadius: s * 0.7,
        options: []
    )

    // Translate the mesh into a centered region — leaves room for the watermark badge bottom-right.
    let meshFrame = CGRect(x: s * 0.16, y: s * 0.10, width: s * 0.68, height: s * 0.78)
    func project(_ v: V) -> CGPoint {
        // Mesh source is origin top-left; CGContext uses bottom-left. Flip y on the way in.
        let x = meshFrame.minX + v.x * meshFrame.width
        let y = meshFrame.minY + (1.0 - v.y) * meshFrame.height
        return CGPoint(x: x, y: y)
    }

    let all = silhouette + interior

    // Skip the fine wireframe at the tiniest sizes — it turns to mush below 32px.
    let drawMesh = size >= 32

    if drawMesh {
        // Wireframe edges. Faint cyan-white, additive feel.
        ctx.setStrokeColor(CGColor(srgbRed: 0.70, green: 0.92, blue: 1.0, alpha: 0.55))
        ctx.setLineWidth(max(0.6, s * 0.0055))
        ctx.setLineCap(.round)
        for e in edges {
            ctx.move(to: project(all[e.0]))
            ctx.addLine(to: project(all[e.1]))
        }
        ctx.strokePath()

        // Vertex dots — every silhouette anchor + interior. Bright on the silhouette, dim inside.
        for (i, v) in all.enumerated() {
            let p = project(v)
            let r = i < silhouette.count ? s * 0.014 : s * 0.011
            let alpha: CGFloat = i < silhouette.count ? 0.95 : 0.75
            ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.98, blue: 1.0, alpha: alpha))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    // Silhouette outline overlaid on top — heavier stroke so the head reads at a glance even
    // when the wireframe blurs out at smaller sizes.
    ctx.beginPath()
    let first = project(silhouette[0])
    ctx.move(to: first)
    for i in 1..<silhouette.count {
        ctx.addLine(to: project(silhouette[i]))
    }
    ctx.closePath()
    ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.92))
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Watermark check badge — bottom-right. The trust thesis in a 16% footprint.
    // Drawn at every size; at tiny sizes it becomes the strongest readable feature.
    let badgeR = s * 0.16
    let badgeCenter = CGPoint(x: s - badgeR * 1.15, y: badgeR * 1.15)
    // Solid green disc with soft inner halo.
    ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.82, blue: 0.45, alpha: 0.98))
    ctx.fillEllipse(in: CGRect(
        x: badgeCenter.x - badgeR,
        y: badgeCenter.y - badgeR,
        width: badgeR * 2,
        height: badgeR * 2
    ))
    // White ring inset.
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.90))
    ctx.setLineWidth(max(1.0, s * 0.010))
    ctx.strokeEllipse(in: CGRect(
        x: badgeCenter.x - badgeR * 0.78,
        y: badgeCenter.y - badgeR * 0.78,
        width: badgeR * 1.56,
        height: badgeR * 1.56
    ))
    // Checkmark stroke.
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1.0))
    ctx.setLineWidth(max(1.2, s * 0.022))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: badgeCenter.x - badgeR * 0.40, y: badgeCenter.y + 0.0))
    ctx.addLine(to: CGPoint(x: badgeCenter.x - badgeR * 0.08, y: badgeCenter.y - badgeR * 0.30))
    ctx.addLine(to: CGPoint(x: badgeCenter.x + badgeR * 0.44, y: badgeCenter.y + badgeR * 0.34))
    ctx.strokePath()

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

func writeIcon(_ variant: IconVariant) throws {
    guard let data = render(size: variant.size) else {
        throw NSError(domain: "iconGen", code: 1)
    }
    let url = outputDir.appendingPathComponent(variant.filename)
    try data.write(to: url)
    print("  wrote \(variant.filename) (\(variant.size)px, \(data.count / 1024) KB)")
}

print("Generating MirrorMesh app icon set (v0.6.0 mesh motif)…")
for v in variants {
    try writeIcon(v)
}

// Contents.json describes the Asset Catalog.
struct Image: Codable {
    let size: String
    let idiom: String
    let filename: String
    let scale: String
}
struct AssetCatalog: Codable {
    let images: [Image]
    let info: Info
    struct Info: Codable {
        let version: Int
        let author: String
    }
}

let images = variants.map { v in
    Image(
        size: "\(v.designSize)x\(v.designSize)",
        idiom: "mac",
        filename: v.filename,
        scale: "\(v.scale)x"
    )
}
let catalog = AssetCatalog(images: images, info: .init(version: 1, author: "xcode"))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let contentsURL = outputDir.appendingPathComponent("Contents.json")
try encoder.encode(catalog).write(to: contentsURL)
print("  wrote Contents.json")

let assetCatalogRoot = URL(fileURLWithPath: "MirrorMesh/Assets.xcassets/Contents.json")
let rootContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try rootContents.write(to: assetCatalogRoot, atomically: true, encoding: .utf8)
print("Done.")
