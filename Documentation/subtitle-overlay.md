# Native subtitle overlay

The native (AVPlayer) player draws subtitles itself in a layer above the video, so the server no longer burns in image subtitles or flattens ASS styling into WebVTT.

## Pieces

- `SubtitleKit/` is a local Swift package that uses only Foundation, CoreGraphics and CoreText. It parses SRT, WebVTT, ASS/SSA and PGS (`.sup`) and rasterizes cues into positioned images. Run its tests on macOS with `swift test --package-path SubtitleKit`; CI runs them too.
- `AVPlayerSubtitleOverlay` (`Shared/Objects/MediaPlayerManager/MediaPlayerProxy/`) fetches the track and any font attachments. It reads the item's timebase on every display refresh and places cue layers over `AVPlayerLayer.videoRect`. Because the overlay reads the player clock, pause, seek and rate changes need no special handling.
- The native device profile requests `External` delivery for `subrip`, `vtt`, `ass`, `ssa` and `pgssub`. `MediaPlayerItem.switchTrack` sends External tracks to the overlay and turns off AVPlayer's own legible rendering. VLC and MPV are unchanged.

## Formats

| Format | Status |
|---|---|
| SRT / WebVTT | Drawn with the user's subtitle font, size and color, plus an outline and shadow. Supports `<b> <i> <u> <s> <font color>`, `{\anN}`, and WebVTT `line:`/`align:`. |
| ASS / SSA | A reduced renderer. See below. |
| PGS | Full decode: palettes, fragmented objects, cropping, palette-only updates and epoch handling. Each object is scaled from the composition's video size to the on-screen video rectangle. |

### ASS: supported

Script and style fields: PlayResX/Y with libass defaults, WrapStyle, ScaledBorderAndShadow, all V4+ style fields, and legacy V4 alignment.

Overrides: `\b \i \u \s \bord \xbord \ybord \shad \xshad \yshad \fn \fs \fscx \fscy \fsp \c \1c \3c \4c \alpha \1a \3a \4a \an \a \q \r \pos \move \org \fad \fade \frz`, and `\be`/`\blur` (approximated with a soft shadow).

Text and layout:
- `\N \n \h` escapes.
- BorderStyle 1 (outline and shadow) and 3 (opaque box).
- VSFilter-style font sizing: ascent plus descent equals the font size.
- Aspect stretch when the script and video aspect ratios differ.
- Smart wrapping that balances line widths.
- Stacking of overlapping bottom- and top-aligned lines, so a line stays put while it is on screen.
- Fonts from MKV attachments are matched by family, full name or PostScript name. Bold and italic are synthesized when a face lacks them.

### ASS: not yet supported (follow-up: libass)

- `\t` transforms: the start state is drawn.
- `\clip` and `\iclip`.
- Karaoke highlighting (`\k \kf \ko`): text is drawn in the primary colour.
- `\frx`, `\fry`, `\fax`, `\fay` and `\fe`.
- `\p` vector drawings: skipped, so drawn signs and masks are missing.
- `[Fonts]` sections embedded in the script.
- True gaussian blur.
- The secondary colour and `\2c`/`\2a`.

## Server requirements

The overlay fetches `/Videos/{id}/{mediaSourceId}/Subtitles/{index}/Stream.{format}` and `/Videos/{id}/{mediaSourceId}/Attachments/{index}`. Embedded ASS, PGS and font attachments need server support in Deadfin. Until then:

- External SRT, VTT and ASS sidecars use the overlay, and so do embedded text tracks in direct-played MP4/MOV files, which the server converts to SRT.
- Embedded ASS in a remux still arrives as HLS WebVTT, which AVPlayer draws natively.
- PGS is still burned in. The profile change does not make this worse than before.

## Known limitations

- The overlay is not part of Picture in Picture.
- Over HDR10 and Dolby Vision output, subtitle white is graphics white (the SDR reference level), the same as the transport bar.
