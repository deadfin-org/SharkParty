//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

/// A Presentation Graphic Stream (Blu-ray `.sup`) track: a sequence of compositions, each shown
/// until the next composition replaces or clears it.
public struct PGSTrack: Sendable {

    /// The video size the composition coordinates refer to.
    public var videoSize: CGSize
    /// Sorted by start; never overlapping.
    public var compositions: [PGSComposition]

    /// The composition visible at `time`, if any.
    public func composition(at time: Double) -> PGSComposition? {
        // Binary search for the last composition starting at or before `time`.
        var low = 0
        var high = compositions.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if compositions[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let found, time < compositions[found].end, !compositions[found].objects.isEmpty else { return nil }

        return compositions[found]
    }
}

public struct PGSComposition: Sendable, Identifiable {

    /// Index in the track; stable identity for caching.
    public var id: Int
    /// Seconds.
    public var start: Double
    /// Seconds; the next composition's start, or `.infinity` for the last one.
    public var end: Double
    public var objects: [PGSPlacedObject]
    /// 256 straight-alpha RGBA entries; unset entries are transparent.
    public var palette: [SubtitleColor]
}

public struct PGSPlacedObject: Sendable {

    public var objectID: Int
    /// Top-left in video coordinates.
    public var x: Int
    public var y: Int
    public var crop: CGRect?
    public var isForced: Bool
    public var object: PGSObject
}

public struct PGSObject: Sendable {
    public var width: Int
    public var height: Int
    /// Run-length encoded indexed pixels.
    public var rle: Data
}

public enum PGSParser {

    enum SegmentType: UInt8 {
        case palette = 0x14
        case object = 0x15
        case presentation = 0x16
        case window = 0x17
        case end = 0x80
    }

    public static func looksLikePGS(_ data: Data) -> Bool {
        data.count >= 13 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x47
    }

    private struct PendingPresentation {
        var pts: Double
        var width: Int
        var height: Int
        var isEpochStart: Bool
        var isPaletteUpdate: Bool
        var paletteID: Int
        var objects: [(objectID: Int, x: Int, y: Int, crop: CGRect?, forced: Bool)]
    }

    public static func parse(_ data: Data) throws -> PGSTrack {
        let bytes = [UInt8](data)
        var offset = 0

        var videoSize = CGSize.zero
        var compositions: [PGSComposition] = []

        // Epoch state: objects and palettes persist until the next epoch start.
        var palettes: [Int: [SubtitleColor]] = [:]
        var objects: [Int: PGSObject] = [:]
        var partialObjects: [Int: (width: Int, height: Int, expected: Int, data: Data)] = [:]
        var pending: PendingPresentation?

        func commit(_ presentation: PendingPresentation) {
            let palette = palettes[presentation.paletteID] ?? Array(repeating: .clear, count: 256)
            let placed: [PGSPlacedObject] = presentation.objects.compactMap { entry in
                guard let object = objects[entry.objectID], object.width > 0, object.height > 0 else { return nil }

                return PGSPlacedObject(
                    objectID: entry.objectID,
                    x: entry.x,
                    y: entry.y,
                    crop: entry.crop,
                    isForced: entry.forced,
                    object: object
                )
            }

            if let last = compositions.indices.last, compositions[last].end > presentation.pts {
                compositions[last].end = presentation.pts
            }

            // Drop zero-length compositions that are immediately replaced at the same timestamp.
            if let last = compositions.last, last.start == presentation.pts {
                compositions.removeLast()
            }

            compositions.append(PGSComposition(
                id: compositions.count,
                start: presentation.pts,
                end: .infinity,
                objects: placed,
                palette: palette
            ))
        }

        while offset + 13 <= bytes.count {
            guard bytes[offset] == 0x50, bytes[offset + 1] == 0x47 else {
                throw SubtitleParseError.malformedPGS("missing PG magic at offset \(offset)")
            }

            let pts = Double(readUInt32(bytes, offset + 2)) / 90000
            let type = bytes[offset + 10]
            let size = Int(readUInt16(bytes, offset + 11))
            let start = offset + 13
            let end = start + size
            guard end <= bytes.count else {
                throw SubtitleParseError.malformedPGS("truncated segment at offset \(offset)")
            }

            let segment = bytes[start ..< end]
            offset = end

            switch SegmentType(rawValue: type) {
            case .presentation:
                guard segment.count >= 11 else { continue }

                let base = segment.startIndex
                let width = Int(readUInt16(bytes, base))
                let height = Int(readUInt16(bytes, base + 2))
                let state = bytes[base + 7]
                let paletteUpdate = bytes[base + 8] & 0x80 != 0
                let paletteID = Int(bytes[base + 9])
                let count = Int(bytes[base + 10])

                var entries: [(objectID: Int, x: Int, y: Int, crop: CGRect?, forced: Bool)] = []
                var cursor = base + 11
                for _ in 0 ..< count {
                    guard cursor + 8 <= end else { break }

                    let objectID = Int(readUInt16(bytes, cursor))
                    let flags = bytes[cursor + 3]
                    let x = Int(readUInt16(bytes, cursor + 4))
                    let y = Int(readUInt16(bytes, cursor + 6))
                    cursor += 8

                    var crop: CGRect?
                    if flags & 0x80 != 0, cursor + 8 <= end {
                        crop = CGRect(
                            x: Int(readUInt16(bytes, cursor)),
                            y: Int(readUInt16(bytes, cursor + 2)),
                            width: Int(readUInt16(bytes, cursor + 4)),
                            height: Int(readUInt16(bytes, cursor + 6))
                        )
                        cursor += 8
                    }
                    entries.append((objectID, x, y, crop, flags & 0x40 != 0))
                }

                if width > 0, height > 0 {
                    videoSize = CGSize(width: width, height: height)
                }

                let isEpochStart = state & 0x80 != 0
                if isEpochStart {
                    palettes.removeAll()
                    objects.removeAll()
                    partialObjects.removeAll()
                }

                pending = PendingPresentation(
                    pts: pts,
                    width: width,
                    height: height,
                    isEpochStart: isEpochStart,
                    isPaletteUpdate: paletteUpdate,
                    paletteID: paletteID,
                    objects: entries
                )

            case .palette:
                guard segment.count >= 2 else { continue }

                let base = segment.startIndex
                let paletteID = Int(bytes[base])
                var palette = palettes[paletteID] ?? Array(repeating: .clear, count: 256)
                var cursor = base + 2
                while cursor + 5 <= end {
                    let entry = Int(bytes[cursor])
                    palette[entry] = PGSColor.rgba(
                        y: bytes[cursor + 1],
                        cr: bytes[cursor + 2],
                        cb: bytes[cursor + 3],
                        alpha: bytes[cursor + 4],
                        // BT.601 for SD (480/576-line) discs, BT.709 otherwise. The PCS precedes the PDS.
                        bt709: videoSize.height == 0 || videoSize.height > 576
                    )
                    cursor += 5
                }
                palettes[paletteID] = palette

            case .object:
                guard segment.count >= 4 else { continue }

                let base = segment.startIndex
                let objectID = Int(readUInt16(bytes, base))
                let sequence = bytes[base + 3]
                let isFirst = sequence & 0x80 != 0
                let isLast = sequence & 0x40 != 0

                if isFirst {
                    guard segment.count >= 11 else { continue }

                    // The length includes the 4 bytes of width and height.
                    let expected = Int(readUInt24(bytes, base + 4)) - 4
                    let width = Int(readUInt16(bytes, base + 7))
                    let height = Int(readUInt16(bytes, base + 9))
                    partialObjects[objectID] = (width, height, expected, Data(bytes[(base + 11) ..< end]))
                } else if var partial = partialObjects[objectID] {
                    partial.data.append(contentsOf: bytes[(base + 4) ..< end])
                    partialObjects[objectID] = partial
                }

                if isLast, let partial = partialObjects.removeValue(forKey: objectID) {
                    objects[objectID] = PGSObject(width: partial.width, height: partial.height, rle: partial.data)
                }

            case .end:
                if let presentation = pending {
                    commit(presentation)
                    pending = nil
                }

            case .window, .none:
                continue
            }
        }

        if let presentation = pending {
            commit(presentation)
        }

        return PGSTrack(videoSize: videoSize, compositions: compositions)
    }

    static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func readUInt24(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
    }

    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

enum PGSColor {

    /// Limited-range YCbCr to straight-alpha sRGB.
    static func rgba(y: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8, bt709: Bool) -> SubtitleColor {
        let luma = 1.164 * (Double(y) - 16)
        let red: Double
        let green: Double
        let blue: Double
        let cbOffset = Double(cb) - 128
        let crOffset = Double(cr) - 128

        if bt709 {
            red = luma + 1.793 * crOffset
            green = luma - 0.213 * cbOffset - 0.533 * crOffset
            blue = luma + 2.112 * cbOffset
        } else {
            red = luma + 1.596 * crOffset
            green = luma - 0.392 * cbOffset - 0.813 * crOffset
            blue = luma + 2.017 * cbOffset
        }

        func clamp(_ value: Double) -> UInt8 {
            UInt8(max(0, min(255, value.rounded())))
        }

        return SubtitleColor(red: clamp(red), green: clamp(green), blue: clamp(blue), alpha: alpha)
    }
}
