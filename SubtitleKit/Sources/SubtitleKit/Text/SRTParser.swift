//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Parses SubRip into a synthesized ASS script. HTML-ish tags (`<i>`, `<b>`, `<u>`, `<s>`, `<font color>`)
/// and the common `{\anN}` positioning extension are preserved as ASS overrides.
public enum SRTParser {

    /// Script height used for synthesized scripts; sizes are fractions of it.
    static let playResY: Double = 1080
    static let playResX: Double = 1920

    public static func parse(_ text: String, style: TextSubtitleStyle = .default) throws -> ASSScript {
        var script = TextScriptFactory.script(style: style)
        let lines = SubtitleText.lines(text).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) }

        var index = 0
        var readOrder = 0

        while index < lines.count {
            // Find the next timing line; tolerate missing or junk sequence numbers.
            guard let (start, end) = parseTiming(lines[index]) else {
                index += 1
                continue
            }

            index += 1

            var body: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
                // A cue with no blank separator before the next one: sequence number followed by timing.
                if index + 1 < lines.count, Int(line.trimmingCharacters(in: .whitespaces)) != nil, parseTiming(lines[index + 1]) != nil {
                    break
                }
                body.append(line)
                index += 1
            }

            guard end > start else { continue }

            let converted = HTMLSubtitleMarkup.toASS(body.joined(separator: "\n"))
            guard !converted.isEmpty else { continue }

            script.events.append(ASSEvent(readOrder: readOrder, start: start, end: end, text: converted))
            readOrder += 1
        }

        guard !script.events.isEmpty else { throw SubtitleParseError.noEvents }

        return script
    }

    static func parseTiming(_ line: String) -> (Double, Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }

        let startText = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let endText = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""

        guard let start = parseTimestamp(startText), let end = parseTimestamp(endText) else { return nil }

        return (start, end)
    }

    /// `HH:MM:SS,mmm`, also accepting `.` and missing hours (`MM:SS.mmm`, used by WebVTT).
    public static func parseTimestamp(_ text: String) -> Double? {
        let normalized = text.replacing(",", with: ".")
        let parts = normalized.split(separator: ":")
        guard (2 ... 3).contains(parts.count) else { return nil }

        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }

            total = total * 60 + value
        }
        return total
    }
}

/// Builds the base script for formats without their own styles.
enum TextScriptFactory {

    static func script(style: TextSubtitleStyle) -> ASSScript {
        let height = SRTParser.playResY
        let outline = style.outlineFraction * height
        let shadow = style.shadowFraction * height
        let margin = style.marginFraction * height

        let defaultStyle = ASSStyle(
            name: "Default",
            fontName: style.fontName,
            fontSize: style.fontHeightFraction * height,
            primaryColor: style.color,
            outlineColor: style.outlineColor,
            backColor: style.outlineColor.withAlpha(160),
            outline: outline,
            shadow: shadow,
            alignment: 2,
            marginL: margin,
            marginR: margin,
            marginV: margin
        )

        return ASSScript(
            playResX: SRTParser.playResX,
            playResY: height,
            wrapStyle: 0,
            scaledBorderAndShadow: true,
            styles: ["Default": defaultStyle],
            events: [],
            usesUniformScale: true
        )
    }
}

/// Converts the HTML-like markup shared by SRT and WebVTT into ASS override text.
enum HTMLSubtitleMarkup {

    static func toASS(_ text: String, isWebVTT: Bool = false) -> String {
        var output = ""
        var index = text.startIndex
        var fontColorDepth = 0
        var skippingRubyText = 0

        while index < text.endIndex {
            let character = text[index]

            if character == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = text[text.index(after: index) ..< close].trimmingCharacters(in: .whitespaces)
                let lowered = tag.lowercased()
                index = text.index(after: close)

                switch lowered {
                case "i": output += "{\\i1}"

                case "/i": output += "{\\i0}"

                case "b": output += "{\\b1}"

                case "/b": output += "{\\b0}"

                case "u": output += "{\\u1}"

                case "/u": output += "{\\u0}"

                case "s": output += "{\\s1}"

                case "/s": output += "{\\s0}"

                case "rt": skippingRubyText += 1

                case "/rt": skippingRubyText = max(0, skippingRubyText - 1)

                case "/font":
                    if fontColorDepth > 0 {
                        fontColorDepth -= 1
                        output += "{\\c}"
                    }

                default:
                    if lowered.hasPrefix("font"), let color = fontColor(in: tag) {
                        fontColorDepth += 1
                        output += "{\\c\(color)}"
                    }
                    // <c.class>, <v Speaker>, <lang>, <ruby>, WebVTT timestamps: dropped.
                }
                continue
            }

            if character == "&",
               isWebVTT || text[index...].hasPrefix("&amp;") || text[index...].hasPrefix("&lt;") || text[index...].hasPrefix("&gt;"),
               let (decoded, next) = decodeEntity(text, at: index)
            {
                if skippingRubyText == 0 {
                    output += decoded
                }
                index = next
                continue
            }

            if skippingRubyText == 0 {
                output.append(character)
            }
            index = text.index(after: index)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing("\n", with: "\\N")
    }

    /// `color="#RRGGBB"` / `color=red` → `&HBBGGRR&`.
    private static func fontColor(in tag: String) -> String? {
        guard let range = tag.range(of: "color", options: .caseInsensitive) else { return nil }

        var value = tag[range.upperBound...].drop(while: { $0 == " " || $0 == "=" })
        value = value.drop(while: { $0 == "\"" || $0 == "'" })
        let raw = value.prefix { $0 != "\"" && $0 != "'" && $0 != " " }.lowercased()

        let named: [String: String] = [
            "white": "ffffff", "black": "000000", "red": "ff0000", "green": "00ff00", "blue": "0000ff",
            "yellow": "ffff00", "cyan": "00ffff", "magenta": "ff00ff", "lime": "00ff00", "gray": "808080",
            "grey": "808080", "orange": "ffa500", "purple": "800080",
        ]

        var hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : (named[raw] ?? raw)
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count >= 6, UInt32(hex.prefix(6), radix: 16) != nil else { return nil }

        let rgb = Array(hex.prefix(6))
        let red = String(rgb[0 ..< 2])
        let green = String(rgb[2 ..< 4])
        let blue = String(rgb[4 ..< 6])
        return "&H\(blue)\(green)\(red)&".uppercased()
    }

    private static func decodeEntity(_ text: String, at index: String.Index) -> (String, String.Index)? {
        guard let semicolon = text[index...].prefix(10).firstIndex(of: ";") else { return nil }

        let name = text[text.index(after: index) ..< semicolon]
        let decoded: String? = switch name {
        case "amp": "&"
        case "lt": "<"
        case "gt": ">"
        case "nbsp": "\u{00A0}"
        case "lrm": "\u{200E}"
        case "rlm": "\u{200F}"
        case "quot": "\""
        case "apos": "'"
        default: nil
        }
        guard let decoded else { return nil }

        return (decoded, text.index(after: semicolon))
    }
}
