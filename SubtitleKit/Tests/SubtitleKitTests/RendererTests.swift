//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation
@testable import SubtitleKit
import Testing

struct RendererTests {

    static let canvas = CGSize(width: 1920, height: 1080)

    static func script(_ events: [ASSEvent]) -> ASSScript {
        ASSScript(
            playResX: 1920,
            playResY: 1080,
            styles: ["Default": ASSStyle(name: "Default", fontName: "Helvetica", fontSize: 60, outline: 3, shadow: 2, marginV: 40)],
            events: events
        )
    }

    @Test
    func `active cues follow the clock`() {
        let renderer = SubtitleRenderer(track: .text(Self.script([
            ASSEvent(readOrder: 0, start: 1, end: 3, text: "A"),
            ASSEvent(readOrder: 1, layer: 1, start: 2, end: 4, text: "B"),
            ASSEvent(readOrder: 2, start: 2.5, end: 2.6, text: "C"),
        ])))

        #expect(renderer.activeIDs(at: 0.99) == [])
        #expect(renderer.activeIDs(at: 1) == [0])
        #expect(renderer.activeIDs(at: 2.55) == [0, 2, 1])
        #expect(renderer.activeIDs(at: 3) == [1])
        #expect(renderer.activeIDs(at: 4) == [])
        #expect(renderer.nextChange(after: 2.55) == 2.6)
    }

    @Test
    func `prerender fills the cache soonest first regardless of file order`() {
        // Typeset scripts often list signs after all dialogue; file order says nothing about timing.
        let renderer = SubtitleRenderer(track: .text(Self.script([
            ASSEvent(readOrder: 0, start: 5, end: 6, text: "Later"),
            ASSEvent(readOrder: 1, start: 1, end: 2, text: "Sooner"),
        ])))
        let canvas = CGSize(width: 640, height: 360)

        #expect(renderer.isRendered([], canvasSize: canvas))
        #expect(!renderer.isRendered([1], canvasSize: canvas))

        renderer.prerender(after: 0, window: 3, canvasSize: canvas)
        #expect(renderer.isRendered([1], canvasSize: canvas))
        #expect(!renderer.isRendered([0], canvasSize: canvas))
        #expect(!renderer.isRendered([1], canvasSize: CGSize(width: 1280, height: 720)))
    }

    @Test
    func `bottom centered placement uses margins`() throws {
        let renderer = SubtitleRenderer(track: .text(Self.script([ASSEvent(readOrder: 0, start: 0, end: 1, text: "Hello")])))
        let subtitle = try #require(renderer.frame(at: 0.5, canvasSize: Self.canvas).subtitles.first)

        let content = subtitle.contentFrame
        #expect(abs(content.midX - 960) < 1)
        #expect(abs(content.maxY - (1080 - 40)) < 1)
        // Cell height matches the ASS font size.
        #expect(abs(content.height - 60) < 2)
        #expect(subtitle.stacking == .up)
        #expect(subtitle.image.width == Int(subtitle.frame.width))
    }

    @Test
    func `explicit position and alignment`() throws {
        let renderer = SubtitleRenderer(track: .text(Self.script([
            ASSEvent(readOrder: 0, start: 0, end: 1, text: "{\\an7\\pos(100,200)}Top-left anchored"),
            ASSEvent(readOrder: 1, start: 0, end: 1, text: "{\\an9}Top right"),
        ])))
        let subtitles = renderer.frame(at: 0.5, canvasSize: Self.canvas).subtitles

        let positioned = try #require(subtitles.first { $0.id == 0 })
        #expect(abs(positioned.contentFrame.minX - 100) < 0.5)
        #expect(abs(positioned.contentFrame.minY - 200) < 0.5)
        #expect(positioned.stacking == .none)

        let topRight = try #require(subtitles.first { $0.id == 1 })
        #expect(abs(topRight.contentFrame.maxX - (1920 - 10)) < 1)
        #expect(abs(topRight.contentFrame.minY - 40) < 1)
        #expect(topRight.stacking == .down)
    }

    @Test
    func `scales from script resolution to canvas`() throws {
        var script = Self.script([ASSEvent(readOrder: 0, start: 0, end: 1, text: "{\\pos(960,540)\\an5}Center")])
        script.playResX = 640
        script.playResY = 360
        let renderer = SubtitleRenderer(track: .text(script))

        let subtitle = try #require(renderer.frame(at: 0.5, canvasSize: CGSize(width: 3840, height: 2160)).subtitles.first)
        // (960,540) in a 640x360 script is (5760,3240) on a 3840x2160 canvas.
        #expect(abs(subtitle.contentFrame.midX - 5760) < 1)
        #expect(abs(subtitle.contentFrame.midY - 3240) < 1)
        // 60px font at 6x scale.
        #expect(abs(subtitle.contentFrame.height - 360) < 8)
    }

    @Test
    func `overlapping bottom cues stack upward`() throws {
        let renderer = SubtitleRenderer(track: .text(Self.script([
            ASSEvent(readOrder: 0, start: 0, end: 4, text: "First speaker"),
            ASSEvent(readOrder: 1, start: 1, end: 3, text: "Second speaker"),
        ])))

        let alone = try #require(renderer.frame(at: 0.5, canvasSize: Self.canvas).subtitles.first)
        let both = renderer.frame(at: 2, canvasSize: Self.canvas).subtitles
        #expect(both.count == 2)

        let first = try #require(both.first { $0.id == 0 })
        let second = try #require(both.first { $0.id == 1 })
        // The earlier line keeps its place; the newcomer sits above it without overlap.
        #expect(first.frame == alone.frame)
        #expect(second.contentFrame.maxY <= first.contentFrame.minY + 1)

        // Positions stay stable while both remain visible.
        let later = renderer.frame(at: 2.5, canvasSize: Self.canvas).subtitles
        #expect(later.first { $0.id == 1 }?.frame == second.frame)
    }

    @Test
    func `wraps long lines within margins`() throws {
        let long = String(repeating: "wrapping words ", count: 20)
        let renderer = SubtitleRenderer(track: .text(Self.script([ASSEvent(readOrder: 0, start: 0, end: 1, text: long)])))
        let subtitle = try #require(renderer.frame(at: 0.5, canvasSize: Self.canvas).subtitles.first)

        #expect(subtitle.contentFrame.width <= 1920 - 20 + 1)
        #expect(subtitle.contentFrame.height > 100)
    }

    @Test
    func `no wrap style keeps one line`() throws {
        let long = String(repeating: "wide ", count: 60)
        let renderer = SubtitleRenderer(track: .text(Self.script([ASSEvent(readOrder: 0, start: 0, end: 1, text: "{\\q2}" + long)])))
        let subtitle = try #require(renderer.frame(at: 0.5, canvasSize: Self.canvas).subtitles.first)
        #expect(subtitle.contentFrame.height < 70)
    }

    @Test
    func `draws visible pixels with outline`() throws {
        let renderer = SubtitleRenderer(track: .text(Self.script([ASSEvent(readOrder: 0, start: 0, end: 1, text: "Hi")])))
        let subtitle = try #require(renderer.frame(at: 0.5, canvasSize: Self.canvas).subtitles.first)

        let pixels = try PGSTests().rgba(subtitle.image)
        var white = 0
        var dark = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] == 255 {
            if pixels[index] > 240 {
                white += 1
            } else if pixels[index] < 16 {
                dark += 1
            }
        }
        #expect(white > 100)
        #expect(dark > 50)
    }

    @Test
    func `horizontal scale draws inside the measured image`() throws {
        // A style ScaleX below 100 (common in fansubs) must narrow the drawn glyphs, not only the image.
        let script = ASSScript(
            playResX: 1920,
            playResY: 1080,
            styles: ["Default": ASSStyle(name: "Default", fontName: "Helvetica", fontSize: 60, scaleX: 50, outline: 0, shadow: 0)],
            events: [ASSEvent(readOrder: 0, start: 0, end: 1, text: "WWWWWWWW")]
        )
        let renderer = SubtitleRenderer(track: .text(script))
        let subtitle = try #require(renderer.frame(at: 0.5, canvasSize: Self.canvas).subtitles.first)

        let image = subtitle.image
        let pixels = try PGSTests().rgba(image)
        var rightmost = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 0 {
            rightmost = max(rightmost, (index / 4) % image.width)
        }
        #expect(rightmost > 0)
        #expect(rightmost < image.width - 1)
    }

    @Test
    func `whitespace and drawing only events render nothing`() {
        let renderer = SubtitleRenderer(track: .text(Self.script([
            ASSEvent(readOrder: 0, start: 0, end: 1, text: "{\\p1}m 0 0 l 10 10{\\p0}"),
            ASSEvent(readOrder: 1, start: 0, end: 1, text: "  \\N "),
        ])))
        #expect(renderer.frame(at: 0.5, canvasSize: Self.canvas).subtitles.isEmpty)
    }

    @Test
    func `attached fonts are matched by family`() throws {
        // Register a system font file as if it came from an MKV attachment.
        let candidates = [
            "/System/Library/Fonts/Supplemental/Courier New.ttf",
            "/System/Library/Fonts/Courier.ttc",
            "/Library/Fonts/Arial Unicode.ttf",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }

        let provider = SubtitleFontProvider()
        let faces = try provider.registerFontData(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(faces > 0)
        #expect(provider.attachedFaceCount > 0)
    }

    @Test
    func `motion interpolates in canvas pixels`() throws {
        let renderer = SubtitleRenderer(track: .text(Self.script([
            ASSEvent(readOrder: 0, start: 10, end: 12, text: "{\\move(0,0,192,108)\\fad(500,0)}Moving"),
        ])))
        let subtitle = try #require(renderer.frame(at: 10, canvasSize: CGSize(width: 3840, height: 2160)).subtitles.first)
        let motion = try #require(subtitle.motion)

        #expect(motion.offset(at: 10) == .zero)
        #expect(motion.offset(at: 11) == CGPoint(x: 192, y: 108))
        #expect(motion.offset(at: 12) == CGPoint(x: 384, y: 216))
        #expect(motion.opacity(at: 10.25) == 0.5)
        #expect(subtitle.stacking == .none)
    }

    @Test
    func `uniform scale for synthesized scripts`() throws {
        let script = try SRTParser.parse("1\n00:00:00,000 --> 00:00:01,000\nWide\n", style: .default)
        let renderer = SubtitleRenderer(track: .text(script))

        // 2.39:1 canvas: glyphs keep their proportions, so the height follows the canvas height only.
        let wide = try #require(renderer.frame(at: 0.5, canvasSize: CGSize(width: 1920, height: 803)).subtitles.first)
        renderer.reset()
        let normal = try #require(renderer.frame(at: 0.5, canvasSize: CGSize(width: 1427, height: 803)).subtitles.first)
        #expect(abs(wide.contentFrame.width - normal.contentFrame.width) < 2)
    }
}
