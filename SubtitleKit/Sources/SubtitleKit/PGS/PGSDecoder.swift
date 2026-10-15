//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

public enum PGSDecoder {

    /// Decodes PGS run-length data into palette indexes, row-major. Short or overlong rows are clipped/padded.
    public static func decodeIndexes(_ object: PGSObject) -> [UInt8] {
        let width = object.width
        let height = object.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rle = [UInt8](object.rle)

        var x = 0
        var y = 0
        var cursor = 0

        func emit(_ color: UInt8, count: Int) {
            guard y < height else { return }

            let run = min(count, max(0, width - x))
            if run > 0, color != 0 {
                let start = y * width + x
                for index in start ..< start + run {
                    pixels[index] = color
                }
            }
            x += count
        }

        while cursor < rle.count, y < height {
            let byte = rle[cursor]
            cursor += 1

            if byte != 0 {
                emit(byte, count: 1)
                continue
            }

            guard cursor < rle.count else { break }

            let flag = rle[cursor]
            cursor += 1

            if flag == 0 {
                // End of line.
                x = 0
                y += 1
                continue
            }

            let isLong = flag & 0x40 != 0
            let hasColor = flag & 0x80 != 0
            var length = Int(flag & 0x3F)

            if isLong {
                guard cursor < rle.count else { break }

                length = length << 8 | Int(rle[cursor])
                cursor += 1
            }

            var color: UInt8 = 0
            if hasColor {
                guard cursor < rle.count else { break }

                color = rle[cursor]
                cursor += 1
            }

            emit(color, count: length)
        }

        return pixels
    }

    /// Renders one object through `palette` into a premultiplied RGBA image.
    public static func image(for placed: PGSPlacedObject, palette: [SubtitleColor]) -> CGImage? {
        let object = placed.object
        let indexes = decodeIndexes(object)

        var lookup = [UInt32](repeating: 0, count: 256)
        for (index, color) in palette.prefix(256).enumerated() {
            let alpha = UInt32(color.alpha)
            let red = (UInt32(color.red) * alpha + 127) / 255
            let green = (UInt32(color.green) * alpha + 127) / 255
            let blue = (UInt32(color.blue) * alpha + 127) / 255
            // Little-endian RGBA bytes in memory: R, G, B, A.
            lookup[index] = red | green << 8 | blue << 16 | alpha << 24
        }

        var rgba = [UInt32](repeating: 0, count: object.width * object.height)
        var anyVisible = false
        for (index, paletteIndex) in indexes.enumerated() {
            let value = lookup[Int(paletteIndex)]
            rgba[index] = value
            if value != 0 {
                anyVisible = true
            }
        }
        guard anyVisible else { return nil }

        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        let image = CGImage(
            width: object.width,
            height: object.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: object.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )

        guard let crop = placed.crop, let image else { return image }

        return image.cropping(to: crop) ?? image
    }
}
