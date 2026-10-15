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

/// Rasterizes one ASS dialogue event with CoreText: shadow, outline (or opaque box), then fill.
enum ASSTextRenderer {

    private static let runIndexKey = NSAttributedString.Key("SubtitleKitRunIndex")
    private static let maxImageDimension: CGFloat = 8192

    private struct PreparedRun {
        let style: ASSRunStyle
        let font: CTFont
        let syntheticBold: Bool
        let border: CGFloat
        let shadow: CGPoint
        let blur: CGFloat
    }

    private struct LaidOutLine {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat

        var height: CGFloat {
            ascent + descent
        }
    }

    static func render(
        event: ASSEvent,
        script: ASSScript,
        canvasSize: CGSize,
        fonts: SubtitleFontProvider
    ) -> RenderedSubtitle? {
        let dialogue = ASSOverrideParser.parse(event: event, script: script)
        guard dialogue.visibleText.contains(where: { !$0.isWhitespace }) else { return nil }
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let scaleX = canvasSize.width / script.playResX
        let scaleY = canvasSize.height / script.playResY
        // VSFilter stretches glyphs when the script and video aspect ratios differ.
        let glyphStretch = script.usesUniformScale ? 1 : scaleX / scaleY
        let borderScale = script.scaledBorderAndShadow ? scaleY : canvasSize.height / 1080

        let prepared: [PreparedRun] = dialogue.runs.map { run in
            let style = run.style
            let resolved = fonts.font(
                name: style.fontName,
                bold: style.bold,
                italic: style.italic,
                cellHeight: style.fontSize * scaleY,
                scaleX: style.scaleX / 100 * glyphStretch,
                scaleY: style.scaleY / 100
            )
            return PreparedRun(
                style: style,
                font: resolved.font,
                syntheticBold: resolved.needsSyntheticBold,
                border: max(style.borderX, style.borderY) * borderScale,
                shadow: CGPoint(x: style.shadowX * borderScale, y: style.shadowY * borderScale),
                blur: style.blur * borderScale
            )
        }

        let attributed = NSMutableAttributedString()
        for (index, run) in dialogue.runs.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): prepared[index].font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                runIndexKey: index,
            ]
            if run.style.spacing != 0 {
                attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = run.style.spacing * scaleX
            }
            attributed.append(NSAttributedString(string: run.text, attributes: attributes))
        }

        let horizontal = (dialogue.alignment - 1) % 3 // 0 left, 1 center, 2 right
        let vertical = (dialogue.alignment - 1) / 3 // 0 bottom, 1 middle, 2 top

        let maxWidth: CGFloat = if dialogue.wrapStyle == 2 {
            .greatestFiniteMagnitude
        } else if dialogue.hasExplicitPosition {
            canvasSize.width
        } else {
            max(1, (script.playResX - dialogue.marginL - dialogue.marginR) * scaleX)
        }

        let lines = layoutLines(attributed, maxWidth: maxWidth, balance: dialogue.wrapStyle == 0 || dialogue.wrapStyle == 3)
        guard !lines.isEmpty else { return nil }

        let blockWidth = lines.map(\.width).max() ?? 0
        let blockHeight = lines.reduce(0) { $0 + $1.height }
        let padding = ceil(prepared.map { $0.border + max(abs($0.shadow.x), abs($0.shadow.y)) + $0.blur * 2 }.max() ?? 0) + 2

        let imageWidth = min(maxImageDimension, ceil(blockWidth + padding * 2))
        let imageHeight = min(maxImageDimension, ceil(blockHeight + padding * 2))
        guard imageWidth >= 1, imageHeight >= 1 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: Int(imageWidth),
            height: Int(imageHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            // BGRA, the layout Core Animation uses natively, so assigning the image needs no conversion.
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.textMatrix = .identity
        context.setLineJoin(.round)
        context.setLineCap(.round)

        // Baseline origins in CoreGraphics (bottom-left) coordinates.
        var origins: [CGPoint] = []
        var top = imageHeight - padding
        for line in lines {
            let x: CGFloat = switch horizontal {
            case 0: padding
            case 1: padding + (blockWidth - line.width) / 2
            default: padding + blockWidth - line.width
            }
            origins.append(CGPoint(x: x, y: top - line.ascent))
            top -= line.height
        }

        if dialogue.borderStyle == 3 {
            drawOpaqueBoxes(context: context, lines: lines, origins: origins, prepared: prepared)
        } else {
            drawPass(.shadow, context: context, lines: lines, origins: origins, prepared: prepared)
            drawPass(.outline, context: context, lines: lines, origins: origins, prepared: prepared)
        }
        drawPass(.fill, context: context, lines: lines, origins: origins, prepared: prepared)

        guard let image = context.makeImage() else { return nil }

        // Anchor point and block placement in canvas pixels (top-left origin).
        let anchor: CGPoint
        let blockLeft: CGFloat
        let blockTop: CGFloat

        if let position = dialogue.position ?? dialogue.move?.from {
            anchor = CGPoint(x: position.x * scaleX, y: position.y * scaleY)
            blockLeft = anchor.x - [0, blockWidth / 2, blockWidth][horizontal]
            blockTop = anchor.y - [blockHeight, blockHeight / 2, 0][vertical]
        } else {
            let left = dialogue.marginL * scaleX
            let right = (script.playResX - dialogue.marginR) * scaleX
            let x: CGFloat = [left, (left + right) / 2, right][horizontal]
            let y: CGFloat = [
                (script.playResY - dialogue.marginV) * scaleY,
                script.playResY / 2 * scaleY,
                dialogue.marginV * scaleY,
            ][vertical]
            anchor = CGPoint(x: x, y: y)
            blockLeft = x - [0, blockWidth / 2, blockWidth][horizontal]
            blockTop = y - [blockHeight, blockHeight / 2, 0][vertical]
        }

        let frame = CGRect(x: blockLeft - padding, y: blockTop - padding, width: imageWidth, height: imageHeight)

        let pivot = dialogue.origin.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) } ?? anchor

        let stacking: RenderedSubtitle.Stacking = if dialogue.hasExplicitPosition || dialogue.rotationZ != 0 {
            .none
        } else {
            [.up, .none, .down][vertical]
        }

        let motion = dialogue.isAnimated
            ? SubtitleMotion(
                scale: CGSize(width: scaleX, height: scaleY),
                move: dialogue.move,
                fade: dialogue.fade,
                start: event.start,
                end: event.end
            )
            : nil

        return RenderedSubtitle(
            id: event.readOrder,
            image: image,
            frame: frame,
            padding: padding,
            canvasSize: canvasSize,
            layer: event.layer,
            readOrder: event.readOrder,
            start: event.start,
            end: event.end,
            stacking: stacking,
            motion: motion,
            rotation: dialogue.rotationZ,
            rotationPivot: pivot
        )
    }

    // MARK: - Layout

    private static func layoutLines(_ attributed: NSAttributedString, maxWidth: CGFloat, balance: Bool) -> [LaidOutLine] {
        var result: [LaidOutLine] = []
        let string = attributed.string as NSString
        var paragraphStart = 0

        while paragraphStart <= string.length {
            let newline = string.range(of: "\n", range: NSRange(location: paragraphStart, length: string.length - paragraphStart))
            let paragraphEnd = newline.location == NSNotFound ? string.length : newline.location
            let range = NSRange(location: paragraphStart, length: paragraphEnd - paragraphStart)

            if range.length == 0 {
                result.append(emptyLine(attributed, at: max(0, min(paragraphStart, attributed.length - 1))))
            } else {
                let paragraph = attributed.attributedSubstring(from: range)
                result.append(contentsOf: breakParagraph(paragraph, maxWidth: maxWidth, balance: balance))
            }

            guard newline.location != NSNotFound else { break }

            paragraphStart = paragraphEnd + 1
        }

        return result
    }

    private static func breakParagraph(_ paragraph: NSAttributedString, maxWidth: CGFloat, balance: Bool) -> [LaidOutLine] {
        let typesetter = CTTypesetterCreateWithAttributedString(paragraph)
        var lines = breakLines(typesetter, length: paragraph.length, width: maxWidth)

        // Smart wrapping: the narrowest width that keeps the same line count gives evenly sized lines.
        if balance, lines.count > 1, maxWidth < .greatestFiniteMagnitude {
            var low = maxWidth / CGFloat(lines.count)
            var high = maxWidth
            var best = lines
            for _ in 0 ..< 10 {
                let mid = (low + high) / 2
                let candidate = breakLines(typesetter, length: paragraph.length, width: mid)
                if candidate.count <= lines.count, candidate.allSatisfy({ $0.width <= mid + 0.5 }) {
                    best = candidate
                    high = mid
                } else {
                    low = mid
                }
            }
            lines = best
        }

        return lines
    }

    private static func breakLines(_ typesetter: CTTypesetter, length: Int, width: CGFloat) -> [LaidOutLine] {
        var lines: [LaidOutLine] = []
        var start = 0

        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 {
                count = length - start
            }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            lines.append(measure(line))
            start += count
        }

        return lines
    }

    private static func measure(_ line: CTLine) -> LaidOutLine {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        return LaidOutLine(line: line, width: max(0, width - trailing), ascent: ascent, descent: descent)
    }

    /// A blank line (`\N\N`) takes the height of the surrounding font.
    private static func emptyLine(_ attributed: NSAttributedString, at location: Int) -> LaidOutLine {
        let attributes = attributed.length > 0 ? attributed.attributes(at: location, effectiveRange: nil) : [:]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: attributes))
        let measured = measure(line)
        return LaidOutLine(line: line, width: 0, ascent: measured.ascent, descent: measured.descent)
    }

    // MARK: - Drawing

    private enum Pass {
        case shadow
        case outline
        case fill
    }

    private static func forEachRun(
        lines: [LaidOutLine],
        origins: [CGPoint],
        prepared: [PreparedRun],
        _ body: (CTRun, CGPoint, PreparedRun) -> Void
    ) {
        for (line, origin) in zip(lines, origins) {
            guard let runs = CTLineGetGlyphRuns(line.line) as? [CTRun] else { continue }

            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let index = attributes[runIndexKey] as? Int, prepared.indices.contains(index) else { continue }

                body(run, origin, prepared[index])
            }
        }
    }

    private static func drawPass(
        _ pass: Pass,
        context: CGContext,
        lines: [LaidOutLine],
        origins: [CGPoint],
        prepared: [PreparedRun]
    ) {
        forEachRun(lines: lines, origins: origins, prepared: prepared) { run, origin, info in
            let style = info.style

            context.saveGState()
            defer { context.restoreGState() }

            switch pass {
            case .shadow:
                guard info.shadow != .zero, style.backColor.alpha > 0 else { return }

                let color = style.backColor.cgColor
                context.translateBy(x: info.shadow.x, y: -info.shadow.y)
                context.setFillColor(color)
                context.setStrokeColor(color)
                context.setLineWidth(info.border * 2)
                context.setTextDrawingMode(info.border > 0 ? .fillStroke : .fill)
                if info.blur > 0 {
                    context.setShadow(offset: .zero, blur: info.blur, color: color)
                }

            case .outline:
                guard info.border > 0, style.outlineColor.alpha > 0 else { return }

                let color = style.outlineColor.cgColor
                context.setFillColor(color)
                context.setStrokeColor(color)
                context.setLineWidth(info.border * 2)
                context.setTextDrawingMode(.fillStroke)
                if info.blur > 0 {
                    context.setShadow(offset: .zero, blur: info.blur, color: color)
                }

            case .fill:
                guard style.primaryColor.alpha > 0 else { return }

                let color = style.primaryColor.cgColor
                context.setFillColor(color)
                context.setStrokeColor(color)
                if info.syntheticBold {
                    context.setLineWidth(CTFontGetSize(info.font) * 0.035)
                    context.setTextDrawingMode(.fillStroke)
                } else {
                    context.setTextDrawingMode(.fill)
                }
                if info.blur > 0, info.border == 0 {
                    context.setShadow(offset: .zero, blur: info.blur, color: color)
                }
            }

            // CTRunDraw ignores the font matrix (\fscx, synthetic italic) unless the run's text matrix is set;
            // layout already measured the scaled advances, so unscaled glyphs would overflow the image.
            context.textMatrix = CTRunGetTextMatrix(run)
            context.textPosition = origin
            CTRunDraw(run, context, CFRange(location: 0, length: 0))

            if pass == .fill, style.underline || style.strikeOut {
                drawDecorations(run: run, origin: origin, font: info.font, style: style, context: context)
            }
        }
    }

    private static func drawDecorations(run: CTRun, origin: CGPoint, font: CTFont, style: ASSRunStyle, context: CGContext) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, &leading))
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)

        let thickness = max(1, CTFontGetUnderlineThickness(font))
        context.setFillColor(style.primaryColor.cgColor)

        if style.underline {
            let y = origin.y + CTFontGetUnderlinePosition(font) - thickness / 2
            context.fill(CGRect(x: origin.x + position.x, y: y, width: width, height: thickness))
        }
        if style.strikeOut {
            let y = origin.y + CTFontGetXHeight(font) / 2 - thickness / 2
            context.fill(CGRect(x: origin.x + position.x, y: y, width: width, height: thickness))
        }
    }

    /// BorderStyle 3: an opaque box in the outline colour behind each line, with a shadow box.
    private static func drawOpaqueBoxes(context: CGContext, lines: [LaidOutLine], origins: [CGPoint], prepared: [PreparedRun]) {
        guard let info = prepared.first else { return }

        for (line, origin) in zip(lines, origins) where line.width > 0 {
            let box = CGRect(
                x: origin.x - info.border,
                y: origin.y - line.descent - info.border,
                width: line.width + info.border * 2,
                height: line.height + info.border * 2
            )

            if info.shadow != .zero, info.style.backColor.alpha > 0 {
                context.setFillColor(info.style.backColor.cgColor)
                context.fill(box.offsetBy(dx: info.shadow.x, dy: -info.shadow.y))
            }
            if info.style.outlineColor.alpha > 0 {
                context.setFillColor(info.style.outlineColor.cgColor)
                context.fill(box)
            }
        }
    }
}
