//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

/// One rasterized subtitle element positioned on a canvas.
///
/// The canvas is the video picture: for text it is the pixel size the renderer was asked for,
/// for PGS it is the composition's video size. The presenter scales `canvasSize` onto the
/// on-screen video rectangle.
public struct RenderedSubtitle: @unchecked Sendable, Identifiable {

    public enum Stacking: Sendable {
        /// Explicitly positioned; never moved by collision handling.
        case none
        /// Bottom-aligned; moves up to avoid overlap.
        case up
        /// Top-aligned; moves down to avoid overlap.
        case down
    }

    public let id: Int
    public let image: CGImage
    /// In canvas pixels, top-left origin, at the event's starting position.
    public var frame: CGRect
    /// Transparent margin around the glyphs inside `frame` (room for outline and shadow).
    public let padding: CGFloat
    public let canvasSize: CGSize
    public let layer: Int
    public let readOrder: Int
    /// Seconds.
    public let start: Double
    /// Seconds.
    public let end: Double
    public let stacking: Stacking
    public let motion: SubtitleMotion?
    /// Degrees, counter-clockwise (ASS `\frz`), around `rotationPivot`.
    public let rotation: Double
    /// In canvas pixels.
    public let rotationPivot: CGPoint

    public var isAnimated: Bool {
        motion != nil
    }

    /// The glyph block without padding.
    var contentFrame: CGRect {
        frame.insetBy(dx: padding, dy: padding)
    }
}

/// Time-dependent placement for `\move` and `\fad`/`\fade`.
public struct SubtitleMotion: Sendable {

    /// Canvas pixels per script unit.
    let scale: CGSize
    let move: ASSMove?
    let fade: ASSFade?
    let start: Double
    let end: Double

    /// Offset in canvas pixels from the subtitle's starting frame.
    public func offset(at time: Double) -> CGPoint {
        guard let move else { return .zero }

        let elapsedMs = (time - start) * 1000
        let point = move.point(atElapsed: elapsedMs, durationMs: (end - start) * 1000)
        return CGPoint(
            x: (point.x - move.from.x) * scale.width,
            y: (point.y - move.from.y) * scale.height
        )
    }

    public func opacity(at time: Double) -> Double {
        guard let fade else { return 1 }

        return fade.opacity(atElapsed: (time - start) * 1000, durationMs: (end - start) * 1000)
    }
}
