//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Parses WebVTT cues into a synthesized ASS script. Cue settings map onto ASS alignment:
/// `line:` near the top selects top alignment, `align:start|end` selects left/right.
/// `STYLE`, `REGION`, and `NOTE` blocks are skipped.
public enum WebVTTParser {

    public static func parse(_ text: String, style: TextSubtitleStyle = .default) -> ASSScript {
        var script = TextScriptFactory.script(style: style)
        let lines = SubtitleText.lines(text).map(String.init)

        var index = 0
        var readOrder = 0

        while index < lines.count {
            let line = lines[index]

            guard line.contains("-->"), let (start, end) = SRTParser.parseTiming(line) else {
                // Skip header, NOTE/STYLE/REGION blocks, and cue identifiers.
                index += 1
                continue
            }

            let settings = cueSettings(line)
            index += 1

            var body: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[index])
                index += 1
            }

            guard end > start else { continue }

            let converted = HTMLSubtitleMarkup.toASS(body.joined(separator: "\n"), isWebVTT: true)
            guard !converted.isEmpty else { continue }

            let alignment = alignment(for: settings)
            let prefix = alignment == 2 ? "" : "{\\an\(alignment)}"
            script.events.append(ASSEvent(readOrder: readOrder, start: start, end: end, text: prefix + converted))
            readOrder += 1
        }

        return script
    }

    static func cueSettings(_ line: String) -> [String: String] {
        guard let arrow = line.range(of: "-->") else { return [:] }

        let tokens = line[arrow.upperBound...].split(separator: " ").dropFirst()

        var settings: [String: String] = [:]
        for token in tokens {
            let pair = token.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }

            settings[String(pair[0]).lowercased()] = String(pair[1]).lowercased()
        }
        return settings
    }

    static func alignment(for settings: [String: String]) -> Int {
        var vertical = 0 // 0 bottom, 1 top
        if let line = settings["line"]?.split(separator: ",").first {
            if line.hasSuffix("%") {
                if let percent = Double(line.dropLast()), percent < 50 {
                    vertical = 1
                }
            } else if let number = Int(line), number >= 0 {
                vertical = 1
            }
        }

        var horizontal = 2
        switch settings["align"] {
        case "start", "left":
            horizontal = 1
        case "end", "right":
            horizontal = 3
        default:
            break
        }

        return vertical == 1 ? horizontal + 6 : horizontal
    }
}
