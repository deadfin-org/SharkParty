//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation
@testable import SubtitleKit
import Testing

struct ASSParserTests {

    static let sample = """
    [Script Info]
    ; comment
    Title: Sample
    ScriptType: v4.00+
    WrapStyle: 0
    ScaledBorderAndShadow: yes
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Open Sans Semibold,74,&H00FFFFFF,&H000000FF,&H00020713,&H80000000,-1,0,0,0,100,100,0,0,1,3.6,1.5,2,150,150,56,1
    Style: Sign,Arial,48,&H0000FFFF,&H000000FF,&H00000000,&H00000000,0,-1,0,0,90,110,1,0,1,2,0,8,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.50,0:00:04.25,Default,,0,0,0,,Line one\\Nline two, with a comma
    Comment: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,not shown
    Dialogue: 1,0:01:02.03,0:01:05.00,Sign,,0,0,90,,{\\an7\\pos(100,200)\\fad(250,500)}Sign {\\c&H0000FF&\\b1}red bold
    Dialogue: 0,1:00:00.00,1:00:01.00,Missing,,0,0,0,,{TL note}Fallback{\\i1}italic
    Dialogue: 0,0:00:10.00,0:00:09.00,Default,,0,0,0,,inverted is dropped
    """

    @Test
    func `parses script info and styles`() throws {
        let script = try ASSParser.parse(Self.sample)

        #expect(script.playResX == 1920)
        #expect(script.playResY == 1080)
        #expect(script.scaledBorderAndShadow)

        let style = try #require(script.styles["Default"])
        #expect(style.fontName == "Open Sans Semibold")
        #expect(style.fontSize == 74)
        #expect(style.bold)
        #expect(!style.italic)
        #expect(style.primaryColor == .white)
        #expect(style.outlineColor == SubtitleColor(red: 0x13, green: 0x07, blue: 0x02))
        // &H80 transparency is ~50% opacity.
        #expect(style.backColor.alpha == 0x7F)
        #expect(style.outline == 3.6)
        #expect(style.marginV == 56)

        let sign = try #require(script.styles["Sign"])
        #expect(sign.alignment == 8)
        #expect(sign.italic)
        #expect(sign.scaleX == 90)
    }

    @Test
    func `parses event timing`() throws {
        let script = try ASSParser.parse(Self.sample)

        #expect(script.events.count == 3)
        #expect(script.events[0].start == 1.5)
        #expect(script.events[0].end == 4.25)
        #expect(script.events[0].text == "Line one\\Nline two, with a comma")
        #expect(abs(script.events[1].start - 62.03) < 0.0001)
        #expect(script.events[1].end == 65)
        #expect(script.events[1].layer == 1)
        #expect(script.events[1].marginV == 90)
        #expect(script.events[2].start == 3600)
        #expect(script.events.map(\.readOrder) == [0, 1, 2])
    }

    @Test
    func `time parsing`() {
        #expect(ASSParser.parseTime("0:00:00.00") == 0)
        #expect(ASSParser.parseTime("1:02:03.45") == 3723.45)
        #expect(ASSParser.parseTime(" 0:00:01.5 ") == 1.5)
        #expect(ASSParser.parseTime("00:01.00") == nil)
    }

    @Test
    func `color parsing`() {
        #expect(ASSParser.parseColor("&H00FF8040") == SubtitleColor(red: 0x40, green: 0x80, blue: 0xFF))
        #expect(ASSParser.parseColor("&HFF000000")?.alpha == 0)
        #expect(ASSParser.parseColor("&H0000FF&") == SubtitleColor(red: 0xFF, green: 0, blue: 0))
        // Decimal (SSA v4) colours.
        #expect(ASSParser.parseColor("16777215") == .white)
    }

    @Test
    func `missing play res defaults to 4 by 3`() throws {
        let script = try ASSParser.parse("[Script Info]\nPlayResY: 720\n[Events]\nDialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,x")
        #expect(script.playResY == 720)
        #expect(script.playResX == 960)
    }

    @Test
    func `legacy V 4 alignment`() throws {
        let script = try ASSParser.parse("""
        [Script Info]
        [V4 Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
        Style: Top,Arial,20,16777215,65535,0,0,0,0,1,2,2,6,10,10,10,0,0
        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:00:00.00,0:00:01.00,Top,,0,0,0,,x
        """)
        #expect(script.styles["Top"]?.alignment == 8)
    }
}

struct ASSOverrideTests {

    @Test
    func `position fade and run styles`() throws {
        let script = try ASSParser.parse(ASSParserTests.sample)
        let dialogue = ASSOverrideParser.parse(event: script.events[1], script: script)

        #expect(dialogue.alignment == 7)
        #expect(dialogue.position == CGPoint(x: 100, y: 200))
        #expect(dialogue.fade == .simple(inMs: 250, outMs: 500))
        #expect(dialogue.marginV == 90)
        #expect(dialogue.runs.count == 2)
        #expect(dialogue.runs[0].text == "Sign ")
        #expect(dialogue.runs[0].style.primaryColor == SubtitleColor(red: 255, green: 255, blue: 0))
        #expect(!dialogue.runs[0].style.bold)
        #expect(dialogue.runs[1].text == "red bold")
        #expect(dialogue.runs[1].style.primaryColor == SubtitleColor(red: 255, green: 0, blue: 0))
        #expect(dialogue.runs[1].style.bold)
    }

    @Test
    func `line breaks comments and fallback style`() throws {
        let script = try ASSParser.parse(ASSParserTests.sample)

        let first = ASSOverrideParser.parse(event: script.events[0], script: script)
        #expect(first.visibleText == "Line one\nline two, with a comma")
        #expect(first.alignment == 2)
        #expect(first.marginV == 56)

        let fallback = ASSOverrideParser.parse(event: script.events[2], script: script)
        #expect(fallback.visibleText == "Fallbackitalic")
        #expect(fallback.runs.first?.style.fontName == "Open Sans Semibold")
        #expect(fallback.runs.last?.style.italic == true)
    }

    @Test
    func `tag prefixes resolve to longest name`() {
        let event = ASSEvent(
            readOrder: 0,
            start: 0,
            end: 1,
            text: "{\\fscx120\\fscy80\\fsp2\\fs40\\bord0\\blur2\\be1\\shad3\\alpha&H80&\\1a&H00&\\an9\\frz15}A"
        )
        let script = ASSScript(styles: ["Default": ASSStyle(name: "Default")])
        let dialogue = ASSOverrideParser.parse(event: event, script: script)
        let style = dialogue.runs[0].style

        #expect(style.scaleX == 120)
        #expect(style.scaleY == 80)
        #expect(style.spacing == 2)
        #expect(style.fontSize == 40)
        #expect(style.borderX == 0)
        #expect(style.blur == 1)
        #expect(style.shadowX == 3)
        #expect(style.outlineColor.alpha == 0x7F)
        #expect(style.primaryColor.alpha == 255)
        #expect(dialogue.alignment == 9)
        #expect(dialogue.rotationZ == 15)
    }

    @Test
    func `drawing mode and unsupported tags are hidden`() {
        let event = ASSEvent(
            readOrder: 0,
            start: 0,
            end: 1,
            text: "{\\p1}m 0 0 l 100 0 100 100{\\p0}{\\k20}Ka{\\kf30}ra{\\t(0,500,\\fs80)\\clip(0,0,10,10)}oke\\hend"
        )
        let script = ASSScript(styles: ["Default": ASSStyle(name: "Default")])
        let dialogue = ASSOverrideParser.parse(event: event, script: script)

        #expect(dialogue.visibleText == "Karaoke\u{00A0}end")
        #expect(dialogue.runs.allSatisfy { $0.style.fontSize == 18 })
    }

    @Test
    func `move and fade curves`() {
        let move = ASSMove(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 50), startMs: 0, endMs: 0)
        #expect(move.point(atElapsed: 0, durationMs: 1000) == CGPoint(x: 0, y: 0))
        #expect(move.point(atElapsed: 500, durationMs: 1000) == CGPoint(x: 50, y: 25))
        #expect(move.point(atElapsed: 2000, durationMs: 1000) == CGPoint(x: 100, y: 50))

        let delayed = ASSMove(from: .zero, to: CGPoint(x: 10, y: 0), startMs: 200, endMs: 400)
        #expect(delayed.point(atElapsed: 100, durationMs: 1000).x == 0)
        #expect(delayed.point(atElapsed: 300, durationMs: 1000).x == 5)

        let fade = ASSFade.simple(inMs: 200, outMs: 400)
        #expect(fade.opacity(atElapsed: 0, durationMs: 1000) == 0)
        #expect(fade.opacity(atElapsed: 100, durationMs: 1000) == 0.5)
        #expect(fade.opacity(atElapsed: 500, durationMs: 1000) == 1)
        #expect(fade.opacity(atElapsed: 800, durationMs: 1000) == 0.5)

        let complex = ASSFade.complex(a1: 255, a2: 0, a3: 255, t1: 0, t2: 100, t3: 900, t4: 1000)
        #expect(complex.opacity(atElapsed: 50, durationMs: 1000) == 0.5)
        #expect(complex.opacity(atElapsed: 500, durationMs: 1000) == 1)
    }
}
