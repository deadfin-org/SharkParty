//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

/// Per-run style after applying override tags to the event's base style.
struct ASSRunStyle: Equatable {

    var fontName: String
    var fontSize: Double
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var strikeOut: Bool
    var scaleX: Double
    var scaleY: Double
    var spacing: Double
    var primaryColor: SubtitleColor
    var outlineColor: SubtitleColor
    var backColor: SubtitleColor
    var borderX: Double
    var borderY: Double
    var shadowX: Double
    var shadowY: Double
    var blur: Double

    init(style: ASSStyle) {
        self.fontName = style.fontName
        self.fontSize = style.fontSize
        self.bold = style.bold
        self.italic = style.italic
        self.underline = style.underline
        self.strikeOut = style.strikeOut
        self.scaleX = style.scaleX
        self.scaleY = style.scaleY
        self.spacing = style.spacing
        self.primaryColor = style.primaryColor
        self.outlineColor = style.outlineColor
        self.backColor = style.backColor
        self.borderX = style.outline
        self.borderY = style.outline
        self.shadowX = style.shadow
        self.shadowY = style.shadow
        self.blur = 0
    }
}

struct ASSRun: Equatable {
    var text: String
    var style: ASSRunStyle
}

/// `\move(x1,y1,x2,y2[,t1,t2])` with times in milliseconds from the event start.
public struct ASSMove: Hashable, Sendable {

    public var from: CGPoint
    public var to: CGPoint
    public var startMs: Double
    public var endMs: Double

    /// The script-space point at `elapsedMs` into an event of `durationMs`.
    public func point(atElapsed elapsedMs: Double, durationMs: Double) -> CGPoint {
        var t1 = startMs
        var t2 = endMs
        if t1 == 0, t2 == 0 {
            t2 = durationMs
        }
        if t2 < t1 {
            swap(&t1, &t2)
        }

        let progress: Double = if elapsedMs <= t1 {
            0
        } else if elapsedMs >= t2 || t2 == t1 {
            1
        } else {
            (elapsedMs - t1) / (t2 - t1)
        }

        return CGPoint(
            x: from.x + (to.x - from.x) * progress,
            y: from.y + (to.y - from.y) * progress
        )
    }
}

/// `\fad(in,out)` and `\fade(a1,a2,a3,t1,t2,t3,t4)` as an opacity curve.
public enum ASSFade: Hashable, Sendable {

    case simple(inMs: Double, outMs: Double)
    /// Alphas are ASS transparency (0 opaque, 255 invisible).
    case complex(a1: Double, a2: Double, a3: Double, t1: Double, t2: Double, t3: Double, t4: Double)

    /// Opacity multiplier in 0...1.
    public func opacity(atElapsed elapsedMs: Double, durationMs: Double) -> Double {
        switch self {
        case let .simple(inMs, outMs):
            var opacity = 1.0
            if inMs > 0, elapsedMs < inMs {
                opacity = min(opacity, max(0, elapsedMs / inMs))
            }
            let remaining = durationMs - elapsedMs
            if outMs > 0, remaining < outMs {
                opacity = min(opacity, max(0, remaining / outMs))
            }
            return opacity

        case let .complex(a1, a2, a3, t1, t2, t3, t4):
            let alpha: Double = if elapsedMs < t1 {
                a1
            } else if elapsedMs < t2 {
                a1 + (a2 - a1) * (elapsedMs - t1) / max(1, t2 - t1)
            } else if elapsedMs < t3 {
                a2
            } else if elapsedMs < t4 {
                a2 + (a3 - a2) * (elapsedMs - t3) / max(1, t4 - t3)
            } else {
                a3
            }
            return 1 - min(255, max(0, alpha)) / 255
        }
    }
}

/// A dialogue event after override-tag interpretation.
struct ASSDialogue {

    var runs: [ASSRun]
    var alignment: Int
    var position: CGPoint?
    var move: ASSMove?
    var origin: CGPoint?
    var fade: ASSFade?
    /// Degrees, counter-clockwise.
    var rotationZ: Double
    var wrapStyle: Int
    var borderStyle: Int
    var marginL: Double
    var marginR: Double
    var marginV: Double

    var hasExplicitPosition: Bool {
        position != nil || move != nil
    }

    var isAnimated: Bool {
        fade != nil || move != nil
    }

    var visibleText: String {
        runs.map(\.text).joined()
    }
}

/// Interprets `{\...}` override blocks. Unsupported tags are parsed and ignored so they never leak into text.
enum ASSOverrideParser {

    static func parse(event: ASSEvent, script: ASSScript) -> ASSDialogue {
        let baseStyle = script.style(named: event.style)
        var current = ASSRunStyle(style: baseStyle)

        var dialogue = ASSDialogue(
            runs: [],
            alignment: baseStyle.alignment,
            position: nil,
            move: nil,
            origin: nil,
            fade: nil,
            rotationZ: baseStyle.angle,
            wrapStyle: script.wrapStyle,
            borderStyle: baseStyle.borderStyle,
            marginL: event.marginL != 0 ? event.marginL : baseStyle.marginL,
            marginR: event.marginR != 0 ? event.marginR : baseStyle.marginR,
            marginV: event.marginV != 0 ? event.marginV : baseStyle.marginV
        )

        var alignmentSet = false
        var rotationLocked = false
        var drawingMode = false
        var pendingText = ""

        func flush() {
            guard !pendingText.isEmpty else { return }

            defer { pendingText = "" }
            guard !drawingMode else { return }

            if let last = dialogue.runs.last, last.style == current {
                dialogue.runs[dialogue.runs.count - 1].text += pendingText
            } else {
                dialogue.runs.append(ASSRun(text: pendingText, style: current))
            }
            rotationLocked = true
        }

        let characters = Array(event.text)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "{", let close = characters[index...].firstIndex(of: "}") {
                flush()
                let block = String(characters[(index + 1) ..< close])
                for tag in splitTags(block) {
                    apply(
                        tag: tag,
                        current: &current,
                        dialogue: &dialogue,
                        baseStyle: baseStyle,
                        script: script,
                        alignmentSet: &alignmentSet,
                        rotationLocked: rotationLocked,
                        drawingMode: &drawingMode
                    )
                }
                index = close + 1
                continue
            }

            if character == "\\", index + 1 < characters.count {
                switch characters[index + 1] {
                case "N":
                    pendingText.append("\n")
                    index += 2
                    continue

                case "n":
                    pendingText.append(dialogue.wrapStyle == 2 ? "\n" : " ")
                    index += 2
                    continue

                case "h":
                    pendingText.append("\u{00A0}")
                    index += 2
                    continue

                default:
                    break
                }
            }

            pendingText.append(character)
            index += 1
        }

        flush()
        return dialogue
    }

    /// Splits an override block into tag bodies (without the leading backslash), respecting parentheses.
    static func splitTags(_ block: String) -> [String] {
        var tags: [String] = []
        var current = ""
        var depth = 0
        var inTag = false

        for character in block {
            if character == "\\", depth == 0 {
                if inTag, !current.isEmpty {
                    tags.append(current)
                }
                current = ""
                inTag = true
                continue
            }
            // Text before the first backslash is a comment (`{TL note}`), not a tag.
            guard inTag else { continue }

            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            }
            current.append(character)
        }

        if inTag, !current.isEmpty {
            tags.append(current)
        }
        return tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Tag names ordered so that longer names win over their prefixes (`fscx` before `fs`, `bord` before `b`).
    private static let tagNames = [
        "xbord", "ybord", "xshad", "yshad", "iclip", "alpha", "fscx", "fscy", "fade", "move", "bord", "shad",
        "blur", "clip", "pbo", "pos", "org", "fsp", "frx", "fry", "frz", "fad", "fax", "fay", "1c", "2c", "3c",
        "4c", "1a", "2a", "3a", "4a", "an", "fn", "fs", "fr", "fe", "be", "kf", "ko", "b", "i", "u", "s", "c",
        "a", "k", "K", "q", "r", "p", "t",
    ]

    // swiftlint:disable:next function_parameter_count
    private static func apply(
        tag: String,
        current: inout ASSRunStyle,
        dialogue: inout ASSDialogue,
        baseStyle: ASSStyle,
        script: ASSScript,
        alignmentSet: inout Bool,
        rotationLocked: Bool,
        drawingMode: inout Bool
    ) {
        guard let name = tagNames.first(where: { tag.hasPrefix($0) }) else { return }

        let argument = String(tag.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        let number = Double(argument)
        let arguments = parenthesized(argument)

        switch name {
        case "b":
            if let weight = Int(argument) {
                current.bold = weight == 1 || weight >= 600
            } else if argument.isEmpty {
                current.bold = baseStyle.bold
            }

        case "i":
            current.italic = argument.isEmpty ? baseStyle.italic : (Int(argument) ?? 0) != 0

        case "u":
            current.underline = argument.isEmpty ? baseStyle.underline : (Int(argument) ?? 0) != 0

        case "s":
            current.strikeOut = argument.isEmpty ? baseStyle.strikeOut : (Int(argument) ?? 0) != 0

        case "bord":
            let value = max(0, number ?? baseStyle.outline)
            current.borderX = value
            current.borderY = value

        case "xbord":
            current.borderX = max(0, number ?? baseStyle.outline)

        case "ybord":
            current.borderY = max(0, number ?? baseStyle.outline)

        case "shad":
            let value = max(0, number ?? baseStyle.shadow)
            current.shadowX = value
            current.shadowY = value

        case "xshad":
            current.shadowX = number ?? baseStyle.shadow

        case "yshad":
            current.shadowY = number ?? baseStyle.shadow

        case "be", "blur":
            current.blur = max(0, number ?? 0)

        case "fn":
            current.fontName = argument.isEmpty ? baseStyle.fontName : argument.trimmingPrefix("@").description

        case "fs":
            if let number, number > 0 {
                if argument.hasPrefix("+") || argument.hasPrefix("-") {
                    current.fontSize = max(1, current.fontSize * (1 + number / 10))
                } else {
                    current.fontSize = number
                }
            } else if argument.isEmpty {
                current.fontSize = baseStyle.fontSize
            }

        case "fscx":
            current.scaleX = number.map { max(0, $0) } ?? baseStyle.scaleX

        case "fscy":
            current.scaleY = number.map { max(0, $0) } ?? baseStyle.scaleY

        case "fsp":
            current.spacing = number ?? baseStyle.spacing

        case "fr", "frz":
            if !rotationLocked {
                dialogue.rotationZ = number ?? baseStyle.angle
            }

        case "c", "1c":
            current.primaryColor = color(argument, keepingAlphaOf: current.primaryColor) ?? baseStyle.primaryColor
                .withAlpha(current.primaryColor.alpha)

        case "3c":
            current.outlineColor = color(argument, keepingAlphaOf: current.outlineColor) ?? baseStyle.outlineColor
                .withAlpha(current.outlineColor.alpha)

        case "4c":
            current.backColor = color(argument, keepingAlphaOf: current.backColor) ?? baseStyle.backColor
                .withAlpha(current.backColor.alpha)

        case "alpha":
            if let alpha = ASSParser.parseAlpha(argument) {
                current.primaryColor.alpha = alpha
                current.outlineColor.alpha = alpha
                current.backColor.alpha = alpha
            } else {
                current.primaryColor.alpha = baseStyle.primaryColor.alpha
                current.outlineColor.alpha = baseStyle.outlineColor.alpha
                current.backColor.alpha = baseStyle.backColor.alpha
            }

        case "1a":
            current.primaryColor.alpha = ASSParser.parseAlpha(argument) ?? baseStyle.primaryColor.alpha

        case "3a":
            current.outlineColor.alpha = ASSParser.parseAlpha(argument) ?? baseStyle.outlineColor.alpha

        case "4a":
            current.backColor.alpha = ASSParser.parseAlpha(argument) ?? baseStyle.backColor.alpha

        case "an":
            if !alignmentSet, let value = Int(argument), (1 ... 9).contains(value) {
                dialogue.alignment = value
                alignmentSet = true
            }

        case "a":
            if !alignmentSet, let value = Int(argument) {
                dialogue.alignment = ASSParser.legacyAlignment(value)
                alignmentSet = true
            }

        case "q":
            if let value = Int(argument) {
                dialogue.wrapStyle = value
            }

        case "r":
            let style = argument.isEmpty ? baseStyle : script.style(named: argument)
            current = ASSRunStyle(style: style)

        case "pos":
            if dialogue.position == nil, dialogue.move == nil, arguments.count >= 2 {
                dialogue.position = CGPoint(x: arguments[0], y: arguments[1])
            }

        case "move":
            if dialogue.position == nil, dialogue.move == nil, arguments.count >= 4 {
                dialogue.move = ASSMove(
                    from: CGPoint(x: arguments[0], y: arguments[1]),
                    to: CGPoint(x: arguments[2], y: arguments[3]),
                    startMs: arguments.count >= 6 ? arguments[4] : 0,
                    endMs: arguments.count >= 6 ? arguments[5] : 0
                )
            }

        case "org":
            if dialogue.origin == nil, arguments.count >= 2 {
                dialogue.origin = CGPoint(x: arguments[0], y: arguments[1])
            }

        case "fad":
            if dialogue.fade == nil, arguments.count >= 2 {
                dialogue.fade = .simple(inMs: arguments[0], outMs: arguments[1])
            }

        case "fade":
            if dialogue.fade == nil {
                if arguments.count >= 7 {
                    dialogue.fade = .complex(
                        a1: arguments[0], a2: arguments[1], a3: arguments[2],
                        t1: arguments[3], t2: arguments[4], t3: arguments[5], t4: arguments[6]
                    )
                } else if arguments.count >= 2 {
                    dialogue.fade = .simple(inMs: arguments[0], outMs: arguments[1])
                }
            }

        case "p":
            drawingMode = (Int(argument) ?? 0) > 0

        default:
            // \k \K \kf \ko (karaoke), \t (transforms), \clip, \iclip, \frx, \fry, \fax, \fay, \fe, \pbo, \2c, \2a:
            // parsed so they do not leak into the text; not rendered yet.
            break
        }
    }

    /// `(a,b,c)` → numbers. Non-numeric arguments (vector clips) are dropped.
    private static func parenthesized(_ argument: String) -> [Double] {
        guard argument.hasPrefix("(") else { return [] }

        let inner = argument.dropFirst().prefix { $0 != ")" }
        return inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func color(_ argument: String, keepingAlphaOf existing: SubtitleColor) -> SubtitleColor? {
        guard !argument.isEmpty, var color = ASSParser.parseColor(argument) else { return nil }

        // Colour overrides carry no alpha; alpha is set separately with \alpha / \Na.
        color.alpha = existing.alpha
        return color
    }
}
