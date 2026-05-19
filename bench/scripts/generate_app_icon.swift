#!/usr/bin/env swift
// Generates MirrorMesh.app's iconset programmatically. Run from repo root:
//
//   swift bench/scripts/generate_app_icon.swift
//
// Writes PNGs into MirrorMesh/Assets.xcassets/AppIcon.appiconset/.
// Idempotent — re-run after changing the design below to refresh all sizes.

import Foundation
import AppKit
import CoreGraphics

let outputDir = URL(fileURLWithPath: "MirrorMesh/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// Sizes per https://developer.apple.com/design/human-interface-guidelines/app-icons (macOS).
// First value is rendered px, second is filename, third is scale (used in Contents.json).
struct IconVariant {
    let size: Int        // pixel size
    let filename: String
    let designSize: Int  // logical size (used in Contents.json)
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

    // Rounded-rect background (macOS Tahoe icon shape — squircle radius ~22% of side).
    let radius = s * 0.225
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Brand gradient: deep indigo → magenta, top-left to bottom-right.
    let colors = [
        CGColor(srgbRed: 0.12, green: 0.07, blue: 0.32, alpha: 1.0),
        CGColor(srgbRed: 0.40, green: 0.12, blue: 0.48, alpha: 1.0),
        CGColor(srgbRed: 0.62, green: 0.18, blue: 0.42, alpha: 1.0),
    ]
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: colors as CFArray,
        locations: [0.0, 0.5, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )

    // Subtle radial highlight top-left
    let highlight = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.18),
            CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: s * 0.35, y: s * 0.78),
        startRadius: 0,
        endCenter: CGPoint(x: s * 0.35, y: s * 0.78),
        endRadius: s * 0.6,
        options: []
    )

    // Mirror motif: two reflected face silhouettes, centered. Stylized as concentric arcs
    // suggesting the camera viewfinder + the mirrored reflection.
    let centerX = s / 2
    let centerY = s / 2
    let mainRadius = s * 0.30

    // Outer ring — viewfinder
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(s * 0.022)
    ctx.addArc(
        center: CGPoint(x: centerX, y: centerY),
        radius: mainRadius,
        startAngle: 0,
        endAngle: .pi * 2,
        clockwise: false
    )
    ctx.strokePath()

    // Vertical mirror line through the center
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
    ctx.setLineWidth(s * 0.012)
    ctx.move(to: CGPoint(x: centerX, y: centerY - mainRadius * 1.15))
    ctx.addLine(to: CGPoint(x: centerX, y: centerY + mainRadius * 1.15))
    ctx.strokePath()

    // Two simple face silhouettes (semi-circles) on each side of the mirror line.
    // Left face — outline only.
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
    ctx.setLineWidth(s * 0.020)
    ctx.beginPath()
    ctx.addArc(
        center: CGPoint(x: centerX - s * 0.06, y: centerY),
        radius: mainRadius * 0.62,
        startAngle: .pi * 0.5,
        endAngle: .pi * 1.5,
        clockwise: false
    )
    ctx.strokePath()

    // Right face — filled with translucent white for the "reflection" effect.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
    ctx.beginPath()
    ctx.addArc(
        center: CGPoint(x: centerX + s * 0.06, y: centerY),
        radius: mainRadius * 0.62,
        startAngle: .pi * 0.5,
        endAngle: .pi * 1.5,
        clockwise: true
    )
    ctx.fillPath()

    // Tiny watermark dot — bottom-right of the viewfinder ring, as a nod to the trust thesis.
    let dotR = s * 0.04
    ctx.setFillColor(CGColor(srgbRed: 0.55, green: 1.0, blue: 0.65, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(
        x: centerX + mainRadius * 0.65 - dotR,
        y: centerY - mainRadius * 0.65 - dotR,
        width: dotR * 2,
        height: dotR * 2
    ))

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

print("Generating MirrorMesh app icon set…")
for v in variants {
    try writeIcon(v)
}

// Generate Contents.json
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

// Top-level Assets.xcassets Contents.json
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
