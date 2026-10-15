//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

/// A straight (non-premultiplied) RGBA color with 8-bit channels.
public struct SubtitleColor: Hashable, Sendable {

    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    /// 255 is opaque.
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = SubtitleColor(red: 255, green: 255, blue: 255)
    public static let black = SubtitleColor(red: 0, green: 0, blue: 0)
    public static let clear = SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0)

    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    func withAlpha(_ alpha: UInt8) -> SubtitleColor {
        var copy = self
        copy.alpha = alpha
        return copy
    }
}

/// Any parsed subtitle track the overlay can present.
public enum SubtitleTrack: Sendable {

    /// Text subtitles (ASS/SSA, and SRT/WebVTT converted into an ASS script).
    case text(ASSScript)
    /// Image subtitles (PGS/SUP).
    case bitmap(PGSTrack)

    /// Detects the format from the payload rather than trusting the URL or codec name.
    public static func parse(_ data: Data, textStyle: TextSubtitleStyle = .default) throws -> SubtitleTrack {
        if PGSParser.looksLikePGS(data) {
            return try .bitmap(PGSParser.parse(data))
        }

        guard let text = SubtitleText.decode(data) else {
            throw SubtitleParseError.unreadableText
        }

        let trimmed = text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        if trimmed.hasPrefix("[Script Info]") || text.contains("[Events]") {
            return try .text(ASSParser.parse(text))
        }
        if trimmed.hasPrefix("WEBVTT") {
            return .text(WebVTTParser.parse(text, style: textStyle))
        }
        return try .text(SRTParser.parse(text, style: textStyle))
    }
}

public enum SubtitleParseError: Error, Equatable {
    case unreadableText
    case noEvents
    case malformedPGS(String)
}

/// Styling applied to formats without their own styles (SRT, WebVTT).
public struct TextSubtitleStyle: Hashable, Sendable {

    public var fontName: String
    /// Line cell height as a fraction of the video height.
    public var fontHeightFraction: Double
    public var color: SubtitleColor
    public var outlineColor: SubtitleColor
    /// Outline width as a fraction of the video height.
    public var outlineFraction: Double
    public var shadowFraction: Double
    /// Bottom margin as a fraction of the video height.
    public var marginFraction: Double

    public init(
        fontName: String,
        fontHeightFraction: Double,
        color: SubtitleColor,
        outlineColor: SubtitleColor = .black,
        outlineFraction: Double = 0.0028,
        shadowFraction: Double = 0.0014,
        marginFraction: Double = 0.05
    ) {
        self.fontName = fontName
        self.fontHeightFraction = fontHeightFraction
        self.color = color
        self.outlineColor = outlineColor
        self.outlineFraction = outlineFraction
        self.shadowFraction = shadowFraction
        self.marginFraction = marginFraction
    }

    public static let `default` = TextSubtitleStyle(
        fontName: "Helvetica Neue",
        fontHeightFraction: 0.05,
        color: .white
    )
}

enum SubtitleText {

    /// UTF-8 (with or without BOM), UTF-16 with BOM, then Windows-1252 as a last resort.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .windowsCP1252)
    }

    /// Splits on CRLF, CR, or LF.
    static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
    }
}
