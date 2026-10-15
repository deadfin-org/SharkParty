//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// A parsed Advanced SubStation Alpha script. SRT and WebVTT are converted into this model too,
/// so a single renderer handles every text format.
public struct ASSScript: Sendable {

    public var playResX: Double
    public var playResY: Double
    /// 0: smart wrap, 1: end-of-line wrap, 2: no wrap, 3: smart wrap with a wider lower line.
    public var wrapStyle: Int
    public var scaledBorderAndShadow: Bool
    public var styles: [String: ASSStyle]
    public var events: [ASSEvent]
    /// Synthesized scripts (SRT/WebVTT) keep glyph proportions instead of stretching to the video aspect.
    public var usesUniformScale: Bool

    public init(
        playResX: Double = 384,
        playResY: Double = 288,
        wrapStyle: Int = 0,
        scaledBorderAndShadow: Bool = true,
        styles: [String: ASSStyle] = [:],
        events: [ASSEvent] = [],
        usesUniformScale: Bool = false
    ) {
        self.playResX = playResX
        self.playResY = playResY
        self.wrapStyle = wrapStyle
        self.scaledBorderAndShadow = scaledBorderAndShadow
        self.styles = styles
        self.events = events
        self.usesUniformScale = usesUniformScale
    }

    /// Exact match first, then case-insensitive, then `Default`, then a stock style.
    public func style(named name: String) -> ASSStyle {
        if let style = styles[name] {
            return style
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces).trimmingPrefix("*")
        if let style = styles.first(where: { $0.key.caseInsensitiveCompare(String(trimmed)) == .orderedSame })?.value {
            return style
        }
        return styles["Default"] ?? ASSStyle(name: "Default")
    }

    /// Font names referenced by styles and `\fn` overrides, for attachment matching and diagnostics.
    public var referencedFontNames: Set<String> {
        var names = Set(styles.values.map(\.fontName))
        for event in events {
            for run in ASSOverrideParser.parse(event: event, script: self).runs {
                names.insert(run.style.fontName)
            }
        }
        return names
    }
}

public struct ASSStyle: Hashable, Sendable {

    public var name: String
    public var fontName: String
    public var fontSize: Double
    public var primaryColor: SubtitleColor
    public var secondaryColor: SubtitleColor
    public var outlineColor: SubtitleColor
    public var backColor: SubtitleColor
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikeOut: Bool
    /// Percent.
    public var scaleX: Double
    /// Percent.
    public var scaleY: Double
    public var spacing: Double
    /// Degrees, counter-clockwise.
    public var angle: Double
    /// 1: outline and drop shadow, 3: opaque box.
    public var borderStyle: Int
    public var outline: Double
    public var shadow: Double
    /// Numpad layout: 1-3 bottom, 4-6 middle, 7-9 top.
    public var alignment: Int
    public var marginL: Double
    public var marginR: Double
    public var marginV: Double

    public init(
        name: String,
        fontName: String = "Arial",
        fontSize: Double = 18,
        primaryColor: SubtitleColor = .white,
        secondaryColor: SubtitleColor = SubtitleColor(red: 255, green: 0, blue: 0),
        outlineColor: SubtitleColor = .black,
        backColor: SubtitleColor = .black,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikeOut: Bool = false,
        scaleX: Double = 100,
        scaleY: Double = 100,
        spacing: Double = 0,
        angle: Double = 0,
        borderStyle: Int = 1,
        outline: Double = 2,
        shadow: Double = 2,
        alignment: Int = 2,
        marginL: Double = 10,
        marginR: Double = 10,
        marginV: Double = 10
    ) {
        self.name = name
        self.fontName = fontName
        self.fontSize = fontSize
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.outlineColor = outlineColor
        self.backColor = backColor
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikeOut = strikeOut
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.spacing = spacing
        self.angle = angle
        self.borderStyle = borderStyle
        self.outline = outline
        self.shadow = shadow
        self.alignment = alignment
        self.marginL = marginL
        self.marginR = marginR
        self.marginV = marginV
    }
}

public struct ASSEvent: Hashable, Sendable {

    /// Position in the file; breaks ties for stacking and drawing order.
    public var readOrder: Int
    public var layer: Int
    /// Seconds.
    public var start: Double
    /// Seconds.
    public var end: Double
    public var style: String
    /// Zero means "use the style's margin".
    public var marginL: Double
    public var marginR: Double
    public var marginV: Double
    /// Raw dialogue text including override blocks.
    public var text: String

    public init(
        readOrder: Int,
        layer: Int = 0,
        start: Double,
        end: Double,
        style: String = "Default",
        marginL: Double = 0,
        marginR: Double = 0,
        marginV: Double = 0,
        text: String
    ) {
        self.readOrder = readOrder
        self.layer = layer
        self.start = start
        self.end = end
        self.style = style
        self.marginL = marginL
        self.marginR = marginR
        self.marginV = marginV
        self.text = text
    }
}
