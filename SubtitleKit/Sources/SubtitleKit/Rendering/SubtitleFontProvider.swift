//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import CoreText
import Foundation

/// Resolves ASS font names against fonts attached to the media (MKV attachments), then installed
/// fonts, then a fallback. Attached fonts are used directly from their descriptors and are never
/// registered process-wide.
public final class SubtitleFontProvider: @unchecked Sendable {

    struct ResolvedFont {
        let font: CTFont
        /// The face lacks the requested weight; the renderer emboldens it.
        let needsSyntheticBold: Bool
    }

    private struct CacheKey: Hashable {
        let name: String
        let bold: Bool
        let italic: Bool
        let cellHeight: Int
        let scaleX: Int
        let scaleY: Int
    }

    private let lock = NSLock()
    private var attachedFaces: [String: [CTFontDescriptor]] = [:]
    private var cache: [CacheKey: ResolvedFont] = [:]
    private var sizeRatioCache: [String: CGFloat] = [:]

    public let fallbackFontName: String?

    public init(fallbackFontName: String? = nil) {
        self.fallbackFontName = fallbackFontName
    }

    /// Number of attached faces available.
    public var attachedFaceCount: Int {
        lock.withLock { Set(attachedFaces.values.flatMap(\.self).map { ObjectIdentifier($0) }).count }
    }

    /// Adds every face in a TTF/OTF/TTC payload. Returns the number of faces added.
    @discardableResult
    public func registerFontData(_ data: Data) -> Int {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] else {
            return 0
        }

        lock.withLock {
            for descriptor in descriptors {
                for key in [kCTFontFamilyNameAttribute, kCTFontNameAttribute, kCTFontDisplayNameAttribute] {
                    guard let name = CTFontDescriptorCopyAttribute(descriptor, key) as? String else { continue }

                    attachedFaces[name.lowercased(), default: []].append(descriptor)
                }
            }
            cache.removeAll()
        }
        return descriptors.count
    }

    /// A font whose ascent + descent equals `cellHeight` pixels, matching VSFilter/libass font sizing.
    func font(
        name: String,
        bold: Bool,
        italic: Bool,
        cellHeight: CGFloat,
        scaleX: CGFloat = 1,
        scaleY: CGFloat = 1
    ) -> ResolvedFont {
        let key = CacheKey(
            name: name.lowercased(),
            bold: bold,
            italic: italic,
            cellHeight: Int((cellHeight * 16).rounded()),
            scaleX: Int((scaleX * 1000).rounded()),
            scaleY: Int((scaleY * 1000).rounded())
        )

        if let cached = lock.withLock({ cache[key] }) {
            return cached
        }

        let (base, needsSyntheticBold, needsSyntheticItalic) = baseFont(name: name, bold: bold, italic: italic)
        let ratio = sizeRatio(for: base)
        let pointSize = max(1, cellHeight * ratio)

        var matrix = CGAffineTransform(scaleX: max(0.01, scaleX), y: max(0.01, scaleY))
        if needsSyntheticItalic {
            matrix = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0).concatenating(matrix)
        }

        let font = CTFontCreateCopyWithAttributes(base, pointSize, &matrix, nil)
        let resolved = ResolvedFont(font: font, needsSyntheticBold: needsSyntheticBold)

        lock.withLock { cache[key] = resolved }
        return resolved
    }

    private func baseFont(name: String, bold: Bool, italic: Bool) -> (CTFont, Bool, Bool) {
        let lowered = name.lowercased()

        if let faces = lock.withLock({ attachedFaces[lowered] }), !faces.isEmpty {
            let best = faces.max { score($0, bold: bold, italic: italic) < score($1, bold: bold, italic: italic) }!
            let font = CTFontCreateWithFontDescriptor(best, 100, nil)
            let traits = CTFontGetSymbolicTraits(font)
            return (
                font,
                bold && !traits.contains(.traitBold),
                italic && !traits.contains(.traitItalic)
            )
        }

        var font = CTFontCreateWithName(name as CFString, 100, nil)
        if !matches(font, name: lowered) {
            font = fallbackFont()
        }

        var traits: CTFontSymbolicTraits = []
        if bold {
            traits.insert(.traitBold)
        }
        if italic {
            traits.insert(.traitItalic)
        }

        guard !traits.isEmpty else { return (font, false, false) }

        if let styled = CTFontCreateCopyWithSymbolicTraits(font, 100, nil, traits, traits) {
            return (styled, false, false)
        }

        // Try each trait separately before synthesizing.
        var result = font
        var syntheticBold = bold
        var syntheticItalic = italic
        if bold, let styled = CTFontCreateCopyWithSymbolicTraits(result, 100, nil, .traitBold, .traitBold) {
            result = styled
            syntheticBold = false
        }
        if italic, let styled = CTFontCreateCopyWithSymbolicTraits(result, 100, nil, .traitItalic, .traitItalic) {
            result = styled
            syntheticItalic = false
        }
        return (result, syntheticBold, syntheticItalic)
    }

    private func fallbackFont() -> CTFont {
        if let fallbackFontName {
            let font = CTFontCreateWithName(fallbackFontName as CFString, 100, nil)
            if matches(font, name: fallbackFontName.lowercased()) {
                return font
            }
        }
        return CTFontCreateUIFontForLanguage(.system, 100, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 100, nil)
    }

    private func matches(_ font: CTFont, name: String) -> Bool {
        let names = [
            CTFontCopyFamilyName(font) as String,
            CTFontCopyFullName(font) as String,
            CTFontCopyPostScriptName(font) as String,
        ]
        return names.contains { $0.lowercased() == name }
    }

    private func score(_ descriptor: CTFontDescriptor, bold: Bool, italic: Bool) -> Int {
        let traits =
            (CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any])?[kCTFontSymbolicTrait] as? UInt32 ?? 0
        let symbolic = CTFontSymbolicTraits(rawValue: traits)
        var score = 0
        if symbolic.contains(.traitBold) == bold {
            score += 2
        }
        if symbolic.contains(.traitItalic) == italic {
            score += 1
        }
        return score
    }

    /// Point size per pixel of cell height for this face.
    private func sizeRatio(for font: CTFont) -> CGFloat {
        let key = CTFontCopyPostScriptName(font) as String
        if let ratio = lock.withLock({ sizeRatioCache[key] }) {
            return ratio
        }

        let size = CTFontGetSize(font)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font)
        let ratio = height > 0 ? size / height : 1
        lock.withLock { sizeRatioCache[key] = ratio }
        return ratio
    }
}
