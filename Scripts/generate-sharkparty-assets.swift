//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// Generate tvOS artwork from the approved, unchanged Design/sharkparty-logo.png.
// Run from the repository root: swift Scripts/generate-sharkparty-assets.swift
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Design/sharkparty-logo.png")
let assets = root.appendingPathComponent("Swiftfin tvOS/Resources/Assets.xcassets")
let brand = assets.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
let input = CGImageSourceCreateWithURL(source as CFURL, nil)!
let logo = CGImageSourceCreateImageAtIndex(input, 0, nil)!
let fm = FileManager.default

func render(width: Int, height: Int, draw: (CGContext) -> Void, to url: URL) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    draw(context)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination), "Unable to write \(url.path)")
}

func logoSquare(size: Int, inset: Int, to path: String) {
    render(width: size, height: size, draw: { context in
        context.draw(logo, in: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset))
    }, to: assets.appendingPathComponent(path))
}

logoSquare(
    size: 216,
    inset: 7,
    to: "App Icon & Top Shelf Image.brandassets/App Icon.imagestack/Front.imagestacklayer/Content.imageset/front.png"
)
logoSquare(
    size: 432,
    inset: 14,
    to: "App Icon & Top Shelf Image.brandassets/App Icon.imagestack/Front.imagestacklayer/Content.imageset/front@2x.png"
)
logoSquare(
    size: 512,
    inset: 16,
    to: "App Icon & Top Shelf Image.brandassets/App Icon - App Store.imagestack/Front.imagestacklayer/Content.imageset/512.png"
)

let logoSet = assets.appendingPathComponent("SharkPartyLogo.imageset")
try fm.createDirectory(at: logoSet, withIntermediateDirectories: true)
logoSquare(size: 512, inset: 0, to: "SharkPartyLogo.imageset/SharkPartyLogo.png")
let logoContents = """
{
  "images" : [{ "filename" : "SharkPartyLogo.png", "idiom" : "universal" }],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try logoContents.write(to: logoSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

func banner(width: Int, scale: Int, to path: String) {
    let height = 720 * scale
    render(width: width * scale, height: height, draw: { context in
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let colors = [
            CGColor(srgbRed: 0.075, green: 0.12, blue: 0.20, alpha: 1),
            CGColor(srgbRed: 0.025, green: 0.035, blue: 0.07, alpha: 1)
        ] as CFArray
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 720),
            end: CGPoint(x: CGFloat(width), y: 0),
            options: []
        )
        let left = CGFloat(width - 1500) / 2
        context.draw(logo, in: CGRect(x: left, y: 60, width: 600, height: 600))
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 146, nil)
        let title = NSAttributedString(string: "SharkParty", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor.white
        ])
        let line = CTLineCreateWithAttributedString(title)
        context.textPosition = CGPoint(x: left + 620, y: 305)
        CTLineDraw(line, context)
    }, to: brand.appendingPathComponent(path))
}

for (folder, width) in [("Top Shelf Image.imageset", 1920), ("Top Shelf Image Wide.imageset", 2320)] {
    banner(width: width, scale: 1, to: "\(folder)/top shelf.png")
    banner(width: width, scale: 1, to: "\(folder)/top shelf-1.png")
    banner(width: width, scale: 2, to: "\(folder)/Untitled-2.png")
    banner(width: width, scale: 2, to: "\(folder)/Untitled-1.png")
}
