//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import SubtitleKit
import Testing

struct SRTParserTests {

    @Test
    func `parses timing and text`() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        Hello

        2
        00:01:02,250 --> 00:01:04,000 X1:10 X2:20 Y1:10 Y2:20
        <i>Two</i>
        lines

        """
        let script = try SRTParser.parse(srt)

        #expect(script.events.count == 2)
        #expect(script.events[0].start == 1.0)
        #expect(script.events[0].end == 2.5)
        #expect(script.events[0].text == "Hello")
        #expect(abs(script.events[1].start - 62.25) < 0.0001)
        #expect(script.events[1].end == 64)
        #expect(script.events[1].text == "{\\i1}Two{\\i0}\\Nlines")
        #expect(script.usesUniformScale)
    }

    @Test
    func `tolerates CRLFBOM and missing indexes`() throws {
        let srt = "\u{FEFF}00:00:00,500 --> 00:00:01,000\r\nFirst\r\n\r\n00:00:02.000 --> 00:00:03.000\r\nSecond\r\n"
        let script = try SRTParser.parse(srt)

        #expect(script.events.map(\.text) == ["First", "Second"])
        #expect(script.events[1].start == 2)
    }

    @Test
    func `keeps alignment override and font color`() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        {\\an8}<font color="#FF8000">Sign</font> &amp; text
        """
        let script = try SRTParser.parse(srt)
        let dialogue = ASSOverrideParser.parse(event: script.events[0], script: script)

        #expect(dialogue.alignment == 8)
        #expect(dialogue.runs.first?.text == "Sign")
        #expect(dialogue.runs.first?.style.primaryColor == SubtitleColor(red: 0xFF, green: 0x80, blue: 0x00))
        #expect(dialogue.runs.last?.text == " & text")
        #expect(dialogue.runs.last?.style.primaryColor == .white)
    }

    @Test
    func `skips inverted and empty cues`() throws {
        let srt = """
        1
        00:00:05,000 --> 00:00:04,000
        Backwards

        2
        00:00:06,000 --> 00:00:07,000
        Kept
        """
        let script = try SRTParser.parse(srt)
        #expect(script.events.map(\.text) == ["Kept"])
    }

    @Test
    func `empty input throws`() {
        #expect(throws: SubtitleParseError.noEvents) {
            try SRTParser.parse("not a subtitle file")
        }
    }
}

struct WebVTTParserTests {

    @Test
    func `parses cues settings and entities`() throws {
        let vtt = """
        WEBVTT

        NOTE a comment

        intro
        00:01.000 --> 00:02.000 line:0 align:start
        <v Narrator><b>Top</b> left &lt;3</v>

        00:00:03.000 --> 00:00:04.000
        Bottom<00:00:03.500> karaoke
        """
        let track = try SubtitleTrack.parse(Data(vtt.utf8))
        guard case let .text(script) = track else {
            Issue.record("expected text track")
            return
        }

        #expect(script.events.count == 2)
        #expect(script.events[0].start == 1)
        #expect(script.events[0].text == "{\\an7}{\\b1}Top{\\b0} left <3")
        #expect(script.events[1].start == 3)
        #expect(script.events[1].text == "Bottom karaoke")
    }
}

struct FormatDetectionTests {

    @Test
    func `detects formats from payload`() throws {
        let ass = "[Script Info]\nPlayResX: 640\nPlayResY: 360\n\n[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,Hi"
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHi\n"

        guard case let .text(assScript) = try SubtitleTrack.parse(Data(ass.utf8)) else {
            Issue.record("expected ASS")
            return
        }

        #expect(assScript.playResX == 640)
        #expect(!assScript.usesUniformScale)

        guard case let .text(srtScript) = try SubtitleTrack.parse(Data(srt.utf8)) else {
            Issue.record("expected SRT")
            return
        }

        #expect(srtScript.usesUniformScale)
    }

    @Test
    func `decodes UTF 16`() throws {
        var data = Data([0xFF, 0xFE])
        try data.append(#require("1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n".data(using: .utf16LittleEndian)))

        guard case let .text(script) = try SubtitleTrack.parse(data) else {
            Issue.record("expected text")
            return
        }

        #expect(script.events.first?.text == "こんにちは")
    }
}
