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

/// Builds `.sup` byte streams for tests.
enum SUPBuilder {

    static func segment(type: UInt8, pts: Double, payload: [UInt8]) -> [UInt8] {
        let ticks = UInt32(pts * 90000)
        var bytes: [UInt8] = [0x50, 0x47]
        bytes += be32(ticks) + be32(0)
        bytes.append(type)
        bytes += be16(payload.count)
        return bytes + payload
    }

    static func presentation(
        pts: Double,
        width: Int = 1920,
        height: Int = 1080,
        epochStart: Bool,
        objects: [(id: Int, x: Int, y: Int)]
    ) -> [UInt8] {
        var payload = be16(width) + be16(height) + [0x10] + be16(0)
        payload.append(epochStart ? 0x80 : 0x00)
        payload += [0x00, 0x00, UInt8(objects.count)]
        for object in objects {
            payload += be16(object.id) + [0x00, 0x00] + be16(object.x) + be16(object.y)
        }
        return segment(type: 0x16, pts: pts, payload: payload)
    }

    static func palette(pts: Double, entries: [(index: UInt8, y: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8)]) -> [UInt8] {
        var payload: [UInt8] = [0x00, 0x00]
        for entry in entries {
            payload += [entry.index, entry.y, entry.cr, entry.cb, entry.alpha]
        }
        return segment(type: 0x14, pts: pts, payload: payload)
    }

    /// Splits the RLE across `fragments` ODS segments.
    static func object(pts: Double, id: Int, width: Int, height: Int, rle: [UInt8], fragments: Int = 1) -> [UInt8] {
        let chunkSize = max(1, Int((Double(rle.count) / Double(fragments)).rounded(.up)))
        let chunks = stride(from: 0, to: rle.count, by: chunkSize).map { Array(rle[$0 ..< min(rle.count, $0 + chunkSize)]) }
        var bytes: [UInt8] = []

        for (index, chunk) in chunks.enumerated() {
            var flags: UInt8 = 0
            if index == 0 {
                flags |= 0x80
            }
            if index == chunks.count - 1 {
                flags |= 0x40
            }

            var payload = be16(id) + [0x00, flags]
            if index == 0 {
                payload += be24(rle.count + 4) + be16(width) + be16(height)
            }
            payload += chunk
            bytes += segment(type: 0x15, pts: pts, payload: payload)
        }
        return bytes
    }

    static func end(pts: Double) -> [UInt8] {
        segment(type: 0x80, pts: pts, payload: [])
    }

    static func be16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func be24(_ value: Int) -> [UInt8] {
        [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

struct PGSTests {

    /// 4x2: row 0 = [1, 1, 0, 0], row 1 = [1, 1, 1, 1].
    static let smallRLE: [UInt8] = [
        0x01, 0x01, 0x00, 0x02, 0x00, 0x00,
        0x00, 0x84, 0x01, 0x00, 0x00,
    ]

    static func sampleStream(fragments: Int = 1) -> Data {
        var bytes: [UInt8] = []
        bytes += SUPBuilder.presentation(pts: 1.0, epochStart: true, objects: [(id: 0, x: 10, y: 20)])
        bytes += SUPBuilder.palette(pts: 1.0, entries: [(1, 235, 128, 128, 255), (2, 16, 128, 128, 128)])
        bytes += SUPBuilder.object(pts: 1.0, id: 0, width: 4, height: 2, rle: smallRLE, fragments: fragments)
        bytes += SUPBuilder.end(pts: 1.0)
        // Clear at 3.5s.
        bytes += SUPBuilder.presentation(pts: 3.5, epochStart: false, objects: [])
        bytes += SUPBuilder.end(pts: 3.5)
        return Data(bytes)
    }

    @Test
    func `parses display sets into timed compositions`() throws {
        let track = try PGSParser.parse(Self.sampleStream())

        #expect(track.videoSize == CGSize(width: 1920, height: 1080))
        #expect(track.compositions.count == 2)

        let first = track.compositions[0]
        #expect(first.start == 1.0)
        #expect(first.end == 3.5)
        #expect(first.objects.count == 1)
        #expect(first.objects[0].x == 10)
        #expect(first.objects[0].y == 20)
        #expect(first.objects[0].object.width == 4)
        #expect(first.palette[1] == SubtitleColor(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(first.palette[2] == SubtitleColor(red: 0, green: 0, blue: 0, alpha: 128))

        #expect(track.composition(at: 0.5) == nil)
        #expect(track.composition(at: 1.0)?.id == 0)
        #expect(track.composition(at: 3.49)?.id == 0)
        #expect(track.composition(at: 3.5) == nil)
        #expect(track.composition(at: 100) == nil)
    }

    @Test
    func `reassembles fragmented objects`() throws {
        let track = try PGSParser.parse(Self.sampleStream(fragments: 3))
        let object = try #require(track.compositions.first?.objects.first?.object)
        #expect(object.rle == Data(Self.smallRLE))
    }

    @Test
    func `decodes run length encoding`() {
        let object = PGSObject(width: 4, height: 2, rle: Data(Self.smallRLE))
        #expect(PGSDecoder.decodeIndexes(object) == [1, 1, 0, 0, 1, 1, 1, 1])
    }

    @Test
    func `decodes long runs`() {
        // 0x40: long run of color 0 (length 0x0102 = 258), 0xC0: long run of color 7 (length 300).
        let rle: [UInt8] = [0x00, 0x41, 0x02, 0x00, 0xC1, 0x2C, 0x07, 0x00, 0x00]
        let object = PGSObject(width: 558, height: 1, rle: Data(rle))
        let pixels = PGSDecoder.decodeIndexes(object)

        #expect(pixels.count == 558)
        #expect(pixels[0 ..< 258].allSatisfy { $0 == 0 })
        #expect(pixels[258...].allSatisfy { $0 == 7 })
    }

    @Test
    func `clips overlong rows and truncated data`() {
        // Row claims 6 pixels in a 4-wide object, then data ends without an end-of-line marker.
        let rle: [UInt8] = [0x00, 0x86, 0x03, 0x00]
        let object = PGSObject(width: 4, height: 2, rle: Data(rle))
        #expect(PGSDecoder.decodeIndexes(object) == [3, 3, 3, 3, 0, 0, 0, 0])
    }

    @Test
    func `renders premultiplied image`() throws {
        let track = try PGSParser.parse(Self.sampleStream())
        let composition = try #require(track.compositions.first)
        let image = try #require(PGSDecoder.image(for: composition.objects[0], palette: composition.palette))

        #expect(image.width == 4)
        #expect(image.height == 2)

        let pixels = try rgba(image)
        // (0,0) opaque white, (2,0) transparent.
        #expect(Array(pixels[0 ..< 4]) == [255, 255, 255, 255])
        #expect(Array(pixels[8 ..< 12]) == [0, 0, 0, 0])
    }

    @Test
    func `renderer positions objects in video coordinates`() throws {
        let track = try PGSParser.parse(Self.sampleStream())
        let renderer = SubtitleRenderer(track: .bitmap(track))

        #expect(renderer.activeIDs(at: 2) == [0])
        let frame = renderer.frame(at: 2, canvasSize: CGSize(width: 3840, height: 2160))
        let subtitle = try #require(frame.subtitles.first)
        #expect(subtitle.frame == CGRect(x: 10, y: 20, width: 4, height: 2))
        #expect(subtitle.canvasSize == CGSize(width: 1920, height: 1080))
        #expect(renderer.frame(at: 4, canvasSize: .zero).subtitles.isEmpty)
    }

    @Test
    func `palette update reuses epoch objects`() throws {
        var bytes = [UInt8](Self.sampleStream())
        // At 5s: show object 0 again with a new palette, without resending the object.
        bytes += SUPBuilder.presentation(pts: 5, epochStart: false, objects: [(id: 0, x: 0, y: 0)])
        bytes += SUPBuilder.palette(pts: 5, entries: [(1, 16, 128, 128, 255)])
        bytes += SUPBuilder.end(pts: 5)

        let track = try PGSParser.parse(Data(bytes))
        let last = try #require(track.compositions.last)
        #expect(last.start == 5)
        #expect(last.objects.count == 1)
        #expect(last.palette[1] == SubtitleColor(red: 0, green: 0, blue: 0, alpha: 255))
    }

    @Test
    func `rejects garbage`() {
        #expect(throws: SubtitleParseError.self) {
            try PGSParser.parse(Data([0x50, 0x47] + [UInt8](repeating: 0, count: 8) + [0x16, 0x00, 0xFF]))
        }
    }

    func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
}
