//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Parses the section/`Format:` structure of ASS and SSA (v4) scripts.
public enum ASSParser {

    private enum Section {
        case scriptInfo
        case styles(isV4Plus: Bool)
        case events
        case other
    }

    private static let defaultStyleFormat = [
        "name", "fontname", "fontsize", "primarycolour", "secondarycolour", "outlinecolour", "backcolour",
        "bold", "italic", "underline", "strikeout", "scalex", "scaley", "spacing", "angle", "borderstyle",
        "outline", "shadow", "alignment", "marginl", "marginr", "marginv", "encoding",
    ]

    private static let defaultEventFormat = [
        "layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text",
    ]

    public static func parse(_ text: String) throws -> ASSScript {
        var script = ASSScript()
        var section = Section.other
        var styleFormat = defaultStyleFormat
        var eventFormat = defaultEventFormat
        var sawPlayResX = false
        var sawPlayResY = false
        var readOrder = 0

        for rawLine in SubtitleText.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                switch line.lowercased() {
                case "[script info]":
                    section = .scriptInfo
                case "[v4+ styles]":
                    section = .styles(isV4Plus: true)
                case "[v4 styles]":
                    section = .styles(isV4Plus: false)
                case "[events]":
                    section = .events
                default:
                    section = .other
                }
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }

            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch section {
            case .scriptInfo:
                switch key {
                case "playresx":
                    if let number = Double(value), number > 0 {
                        script.playResX = number
                        sawPlayResX = true
                    }

                case "playresy":
                    if let number = Double(value), number > 0 {
                        script.playResY = number
                        sawPlayResY = true
                    }

                case "wrapstyle":
                    script.wrapStyle = Int(value) ?? 0

                case "scaledborderandshadow":
                    script.scaledBorderAndShadow = value.lowercased() != "no"

                default:
                    break
                }

            case let .styles(isV4Plus):
                if key == "format" {
                    styleFormat = formatFields(value)
                } else if key == "style" {
                    let style = parseStyle(value, format: styleFormat, isV4Plus: isV4Plus)
                    script.styles[style.name] = style
                }

            case .events:
                if key == "format" {
                    eventFormat = formatFields(value)
                } else if key == "dialogue" {
                    if let event = parseEvent(value, format: eventFormat, readOrder: readOrder) {
                        script.events.append(event)
                        readOrder += 1
                    }
                }

            case .other:
                break
            }
        }

        // libass/VSFilter defaults: a missing dimension is derived from the other assuming 4:3,
        // except the common 1280x1024 case.
        switch (sawPlayResX, sawPlayResY) {
        case (false, false):
            script.playResX = 384
            script.playResY = 288

        case (true, false):
            script.playResY = script.playResX == 1280 ? 1024 : (script.playResX * 3 / 4).rounded()

        case (false, true):
            script.playResX = script.playResY == 1024 ? 1280 : (script.playResY * 4 / 3).rounded()

        case (true, true):
            break
        }

        guard !script.events.isEmpty else { throw SubtitleParseError.noEvents }

        return script
    }

    static func formatFields(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Splits into `count` fields; the last field keeps any remaining commas (dialogue text).
    static func fields(_ value: String, count: Int) -> [String] {
        guard count > 0 else { return [] }

        return value.split(separator: ",", maxSplits: count - 1, omittingEmptySubsequences: false).map(String.init)
    }

    static func parseStyle(_ value: String, format: [String], isV4Plus: Bool) -> ASSStyle {
        let values = fields(value, count: format.count)
        var style = ASSStyle(name: "Default")

        for (key, raw) in zip(format, values) {
            let field = raw.trimmingCharacters(in: .whitespaces)
            switch key {
            case "name": style.name = field

            case "fontname": style.fontName = field.trimmingPrefix("@").description

            case "fontsize": style.fontSize = Double(field) ?? style.fontSize

            case "primarycolour", "primarycolor": style.primaryColor = parseColor(field) ?? style.primaryColor

            case "secondarycolour", "secondarycolor": style.secondaryColor = parseColor(field) ?? style.secondaryColor

            case "outlinecolour", "outlinecolor", "tertiarycolour": style.outlineColor = parseColor(field) ?? style.outlineColor

            case "backcolour", "backcolor": style.backColor = parseColor(field) ?? style.backColor

            case "bold": style.bold = (Int(field) ?? 0) != 0

            case "italic": style.italic = (Int(field) ?? 0) != 0

            case "underline": style.underline = (Int(field) ?? 0) != 0

            case "strikeout": style.strikeOut = (Int(field) ?? 0) != 0

            case "scalex": style.scaleX = Double(field) ?? 100

            case "scaley": style.scaleY = Double(field) ?? 100

            case "spacing": style.spacing = Double(field) ?? 0

            case "angle": style.angle = Double(field) ?? 0

            case "borderstyle": style.borderStyle = Int(field) ?? 1

            case "outline": style.outline = max(0, Double(field) ?? 0)

            case "shadow": style.shadow = max(0, Double(field) ?? 0)

            case "alignment":
                let raw = Int(field) ?? 2
                style.alignment = isV4Plus ? clampAlignment(raw) : legacyAlignment(raw)

            case "marginl": style.marginL = Double(field) ?? 0

            case "marginr": style.marginR = Double(field) ?? 0

            case "marginv": style.marginV = Double(field) ?? 0

            default: break
            }
        }

        // SSA v4 back colour doubles as the shadow colour, which matches V4+ semantics.
        return style
    }

    static func parseEvent(_ value: String, format: [String], readOrder: Int) -> ASSEvent? {
        let values = fields(value, count: format.count)
        guard values.count == format.count else { return nil }

        var event = ASSEvent(readOrder: readOrder, start: 0, end: 0, text: "")
        var hasStart = false
        var hasEnd = false

        for (key, raw) in zip(format, values) {
            switch key {
            case "layer", "marked":
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                event.layer = Int(trimmed.replacing("Marked=", with: "")) ?? 0

            case "start":
                if let time = parseTime(raw) {
                    event.start = time
                    hasStart = true
                }

            case "end":
                if let time = parseTime(raw) {
                    event.end = time
                    hasEnd = true
                }

            case "style": event.style = raw.trimmingCharacters(in: .whitespaces)

            case "marginl": event.marginL = Double(raw.trimmingCharacters(in: .whitespaces)) ?? 0

            case "marginr": event.marginR = Double(raw.trimmingCharacters(in: .whitespaces)) ?? 0

            case "marginv": event.marginV = Double(raw.trimmingCharacters(in: .whitespaces)) ?? 0

            case "text": event.text = raw

            default: break
            }
        }

        guard hasStart, hasEnd, event.end > event.start else { return nil }

        return event
    }

    /// `H:MM:SS.cc` (centiseconds), tolerant of extra fractional digits.
    public static func parseTime(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else { return nil }

        return hours * 3600 + minutes * 60 + seconds
    }

    /// `&HAABBGGRR&`, `&HBBGGRR`, or a decimal integer. ASS alpha 00 is opaque.
    public static func parseColor(_ raw: String) -> SubtitleColor? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        let isHex = text.lowercased().hasPrefix("&h") || text.lowercased().hasPrefix("h")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "&Hh"))

        let value: UInt32? = if isHex {
            UInt32(text.prefix(8), radix: 16)
        } else if let decimal = Int64(text) {
            UInt32(truncatingIfNeeded: decimal)
        } else {
            UInt32(text.prefix(8), radix: 16)
        }

        guard let value else { return nil }

        return SubtitleColor(
            red: UInt8(value & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8((value >> 16) & 0xFF),
            alpha: 255 - UInt8((value >> 24) & 0xFF)
        )
    }

    /// `&HAA&` alpha override to an opacity byte (255 opaque).
    static func parseAlpha(_ raw: String) -> UInt8? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "&Hh ")).prefix(2)
        guard let value = UInt8(text, radix: 16) else { return nil }

        return 255 - value
    }

    static func clampAlignment(_ value: Int) -> Int {
        (1 ... 9).contains(value) ? value : 2
    }

    /// SSA v4 alignment: 1-3 bottom, +4 top, +8 middle.
    static func legacyAlignment(_ value: Int) -> Int {
        let horizontal = value & 3
        guard horizontal != 0 else { return 2 }

        if value & 4 != 0 {
            return horizontal + 6
        }
        if value & 8 != 0 {
            return horizontal + 3
        }
        return horizontal
    }
}
