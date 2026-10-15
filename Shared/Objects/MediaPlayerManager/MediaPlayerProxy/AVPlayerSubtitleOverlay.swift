//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Defaults
import Foundation
import JellyfinAPI
import Logging
import QuartzCore
import SubtitleKit
import SwiftUI
import UIKit

/// Draws ASS/SSA, PGS, SRT, and WebVTT subtitles in a layer above `AVPlayerLayer`.
///
/// Timing comes from the current item's timebase, read on every display refresh, so pause,
/// seek, and rate changes need no extra handling: the visible cue set is recomputed whenever
/// it changes. Images are rasterized at the on-screen pixel size of the video rectangle and
/// upcoming cues are prerendered on a background queue.
///
/// The layer is composited by the system like the transport bar, so it stays legible over
/// HDR10 and Dolby Vision output (graphics white maps to the display's SDR reference level).
@MainActor
final class AVPlayerSubtitleOverlay: NSObject {

    /// Container positioned on the video rectangle; add it above the player layer.
    let layer = CALayer()

    private weak var player: AVPlayer?
    private weak var playerLayer: AVPlayerLayer?
    private let logger = Logger.swiftfin()

    private var renderer: SubtitleRenderer?
    private var displayLink: CADisplayLink?
    private var loadTask: Task<Void, Never>?

    private var currentKey: [Int]?
    private var visible: [RenderedSubtitle] = []
    private var cueLayers: [Int: CALayer] = [:]

    private var videoRect: CGRect = .zero
    private var screenScale: CGFloat = 1

    private let prerenderQueue = DispatchQueue(label: "org.deadfin.SharkParty.subtitle-prerender", qos: .utility)
    /// Draws cues needed now that prerendering missed; never the main thread, which would drop video frames.
    private let renderQueue = DispatchQueue(label: "org.deadfin.SharkParty.subtitle-render", qos: .userInteractive)
    /// The cue set being drawn on `renderQueue`, if any.
    private var pendingKey: [Int]?
    private var lastPrerenderTime: Double = -.infinity
    private var isPrerendering = false

    /// The Jellyfin index of the stream being shown, if any.
    private(set) var streamIndex: Int?

    init(player: AVPlayer, playerLayer: AVPlayerLayer) {
        self.player = player
        self.playerLayer = playerLayer
        super.init()

        layer.masksToBounds = false
        layer.zPosition = 1
        layer.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    // MARK: - Track Selection

    /// Fetches, parses, and starts presenting `stream`. Replaces any current track.
    func show(stream: MediaStream, item: MediaPlayerItem, client: JellyfinClient) {
        clear()

        guard let url = Self.subtitleURL(for: stream, item: item, client: client) else {
            logger.warning("Subtitle overlay: no delivery URL for stream \(stream.index ?? -1)")
            return
        }

        streamIndex = stream.index
        let style = Self.textStyle(from: Defaults[.VideoPlayer.Subtitle.configuration])
        let attachments = Self.fontAttachmentURLs(for: item, client: client)
        let logger = logger

        loadTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                    throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url, "status": http.statusCode])
                }
                try Task.checkCancellation()

                let track = try await Task.detached(priority: .userInitiated) {
                    try SubtitleTrack.parse(data, textStyle: style)
                }.value

                let fonts = SubtitleFontProvider(fallbackFontName: style.fontName)
                if case let .text(script) = track, !script.usesUniformScale, !attachments.isEmpty {
                    let faces = await Self.loadFonts(from: attachments, into: fonts)
                    logger.debug("Subtitle overlay: loaded \(faces) attached font face(s)")
                }
                try Task.checkCancellation()

                self?.start(renderer: SubtitleRenderer(track: track, fonts: fonts))
            } catch is CancellationError {
                return
            } catch {
                logger.error("Subtitle overlay: failed to load stream \(stream.index ?? -1): \(error.localizedDescription)")
            }
        }
    }

    /// Stops presenting and drops all cached images.
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        displayLink?.invalidate()
        displayLink = nil
        renderer = nil
        streamIndex = nil
        currentKey = nil
        pendingKey = nil
        visible = []
        lastPrerenderTime = -.infinity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cueLayers.values.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        cueLayers.removeAll()
    }

    /// Pixels per point of the screen showing the video; text is rasterized at this density.
    func setScreenScale(_ scale: CGFloat) {
        let scale = max(1, scale)
        guard scale != screenScale else { return }

        screenScale = scale
        invalidateRasterization()
    }

    /// Follows the player layer's video rectangle, which changes with layout and when the
    /// item's presentation size becomes known. Called on layout and on every tick.
    func updateGeometry() {
        guard let playerLayer else { return }

        let videoRect = playerLayer.videoRect
        let rect = (videoRect.isEmpty ? playerLayer.bounds : videoRect)
            .offsetBy(dx: playerLayer.frame.minX, dy: playerLayer.frame.minY)
        guard rect != self.videoRect else { return }

        self.videoRect = rect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = rect
        CATransaction.commit()

        invalidateRasterization()
    }

    /// Text is rasterized for the new pixel size on the next tick.
    private func invalidateRasterization() {
        currentKey = nil
        lastPrerenderTime = -.infinity
    }

    // MARK: - Presentation

    private func start(renderer: SubtitleRenderer) {
        self.renderer = renderer
        currentKey = nil

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private var canvasSize: CGSize {
        CGSize(width: (videoRect.width * screenScale).rounded(), height: (videoRect.height * screenScale).rounded())
    }

    private var mediaTime: Double? {
        guard let item = player?.currentItem else { return nil }

        let time = item.timebase?.time ?? item.currentTime()
        guard time.isNumeric else { return nil }

        return time.seconds
    }

    @objc
    private func tick() {
        updateGeometry()

        guard let renderer, let time = mediaTime, videoRect.width > 0, videoRect.height > 0 else { return }

        let ids = renderer.activeIDs(at: time)
        if ids != currentKey {
            let canvas = canvasSize
            if renderer.isRendered(ids, canvasSize: canvas) {
                currentKey = ids
                apply(renderer.frame(at: time, canvasSize: canvas))
            } else {
                renderInBackground(renderer: renderer, ids: ids, time: time, canvas: canvas)
            }
        }

        if visible.contains(where: \.isAnimated) {
            place(time: time)
        }

        prerenderIfNeeded(renderer: renderer, time: time)
    }

    private func apply(_ frame: SubtitleFrame) {
        visible = frame.subtitles

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let ids = Set(frame.subtitles.map(\.id))
        for (id, cueLayer) in cueLayers where !ids.contains(id) {
            cueLayer.removeFromSuperlayer()
            cueLayers.removeValue(forKey: id)
        }

        for subtitle in frame.subtitles {
            let cueLayer: CALayer
            if let existing = cueLayers[subtitle.id] {
                cueLayer = existing
            } else {
                cueLayer = CALayer()
                cueLayer.contentsGravity = .resize
                cueLayer.actions = [
                    "contents": NSNull(),
                    "position": NSNull(),
                    "bounds": NSNull(),
                    "anchorPoint": NSNull(),
                    "opacity": NSNull(),
                    "transform": NSNull(),
                    "zPosition": NSNull(),
                ]
                layer.addSublayer(cueLayer)
                cueLayers[subtitle.id] = cueLayer
            }

            cueLayer.contents = subtitle.image
        }

        // Draw back to front.
        for (order, subtitle) in frame.subtitles.enumerated() {
            cueLayers[subtitle.id]?.zPosition = CGFloat(order)
        }

        place(time: mediaTime ?? 0, inTransaction: true)
    }

    /// Maps canvas pixels onto the video rectangle and applies motion, fades, and rotation.
    private func place(time: Double, inTransaction: Bool = false) {
        if !inTransaction {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        defer {
            if !inTransaction {
                CATransaction.commit()
            }
        }

        for subtitle in visible {
            guard let cueLayer = cueLayers[subtitle.id],
                  subtitle.canvasSize.width > 0, subtitle.canvasSize.height > 0
            else { continue }

            let scaleX = videoRect.width / subtitle.canvasSize.width
            let scaleY = videoRect.height / subtitle.canvasSize.height
            let offset = subtitle.motion?.offset(at: time) ?? .zero

            let frame = CGRect(
                x: (subtitle.frame.minX + offset.x) * scaleX,
                y: (subtitle.frame.minY + offset.y) * scaleY,
                width: subtitle.frame.width * scaleX,
                height: subtitle.frame.height * scaleY
            )
            let pivot = subtitle.rotation == 0
                ? frame.origin
                : CGPoint(x: (subtitle.rotationPivot.x + offset.x) * scaleX, y: (subtitle.rotationPivot.y + offset.y) * scaleY)

            cueLayer.bounds = CGRect(origin: .zero, size: frame.size)
            cueLayer.anchorPoint = CGPoint(
                x: frame.width > 0 ? (pivot.x - frame.minX) / frame.width : 0,
                y: frame.height > 0 ? (pivot.y - frame.minY) / frame.height : 0
            )
            cueLayer.position = pivot
            // ASS angles are counter-clockwise; UIKit layers have a downward y axis.
            cueLayer.transform = subtitle.rotation == 0
                ? CATransform3DIdentity
                : CATransform3DMakeRotation(-subtitle.rotation * .pi / 180, 0, 0, 1)
            cueLayer.opacity = Float(subtitle.motion?.opacity(at: time) ?? 1)
        }
    }

    /// Keeps the current cues up until the new set is drawn, a frame or two later at most.
    private func renderInBackground(renderer: SubtitleRenderer, ids: [Int], time: Double, canvas: CGSize) {
        guard pendingKey != ids else { return }

        pendingKey = ids
        renderQueue.async { [weak self] in
            let frame = renderer.frame(at: time, canvasSize: canvas)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.renderer === renderer, self.pendingKey == ids else { return }

                    self.pendingKey = nil
                    // Skip a set that is already gone (seek, fast cue churn); the next tick schedules the current one.
                    guard let now = self.mediaTime, renderer.activeIDs(at: now) == ids, self.canvasSize == canvas else { return }

                    self.currentKey = ids
                    self.apply(frame)
                }
            }
        }
    }

    private func prerenderIfNeeded(renderer: SubtitleRenderer, time: Double) {
        guard !isPrerendering, abs(time - lastPrerenderTime) > 0.5 else { return }

        lastPrerenderTime = time
        isPrerendering = true
        let canvas = canvasSize

        prerenderQueue.async { [weak self] in
            renderer.prerender(after: time, window: 6, canvasSize: canvas)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.isPrerendering = false
                }
            }
        }
    }
}

// MARK: - Sources

extension AVPlayerSubtitleOverlay {

    /// Formats the overlay can draw. Matches the External profiles advertised for the native player.
    static let supportedCodecs: Set<String> = ["ass", "ssa", "pgssub", "pgs", "sup", "subrip", "srt", "vtt", "webvtt"]

    /// Whether the overlay should handle `stream` instead of AVPlayer's legible track selection:
    /// streams the server delivers as External, and sidecar files the server has not planned yet
    /// (Deadfin only fills in delivery details for the stream selected at playback start).
    static func canPresent(_ stream: MediaStream) -> Bool {
        let isSupportedCodec = stream.codec.map { supportedCodecs.contains($0.lowercased()) } ?? false

        switch stream.deliveryMethod {
        case .external:
            // The server may convert (e.g. mov_text to subrip); the payload format is detected on load.
            return stream.deliveryURL != nil || isSupportedCodec
        case nil:
            return stream.isExternal == true && isSupportedCodec
        default:
            return false
        }
    }

    static func subtitleURL(for stream: MediaStream, item: MediaPlayerItem, client: JellyfinClient) -> URL? {
        if let deliveryURL = stream.deliveryURL {
            if stream.isExternalURL == true, let url = URL(string: deliveryURL) {
                return url
            }
            return stream.url(with: client)
        }

        // Only the selected stream carries a delivery URL; build the same route for others.
        guard let itemID = item.baseItem.id,
              let mediaSourceID = item.mediaSource.id,
              let index = stream.index,
              let codec = stream.codec?.lowercased()
        else { return nil }

        let request = Paths.getSubtitle(routeItemID: itemID, routeMediaSourceID: mediaSourceID, routeIndex: index, routeFormat: codec)
        return client.url(with: request, queryAPIKey: true)
    }

    static func fontAttachmentURLs(for item: MediaPlayerItem, client: JellyfinClient) -> [URL] {
        guard let itemID = item.baseItem.id, let mediaSourceID = item.mediaSource.id else { return [] }

        return (item.mediaSource.mediaAttachments ?? [])
            .filter { attachment in
                let mime = attachment.mimeType?.lowercased() ?? ""
                let name = attachment.fileName?.lowercased() ?? ""
                return mime.contains("font") || mime.contains("truetype") || mime.contains("opentype")
                    || name.hasSuffix(".ttf") || name.hasSuffix(".otf") || name.hasSuffix(".ttc")
            }
            .compactMap { attachment in
                guard let index = attachment.index else { return nil }

                return client.url(
                    with: Paths.getAttachment(videoID: itemID, mediaSourceID: mediaSourceID, index: index),
                    queryAPIKey: true
                )
            }
    }

    /// Downloads attached fonts concurrently; failures are skipped (the renderer falls back).
    static func loadFonts(from urls: [URL], into fonts: SubtitleFontProvider) async -> Int {
        let limit = 64
        return await withTaskGroup(of: Data?.self) { group in
            for url in urls.prefix(limit) {
                group.addTask {
                    guard let result = try? await URLSession.shared.data(from: url) else { return nil }

                    if let http = result.1 as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                        return nil
                    }
                    return result.0
                }
            }

            var faces = 0
            for await data in group {
                if let data {
                    faces += fonts.registerFontData(data)
                }
            }
            return faces
        }
    }

    /// The user's subtitle settings for formats without their own styling (SRT, WebVTT).
    static func textStyle(from configuration: SubtitleConfiguration) -> TextSubtitleStyle {
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        UIColor(configuration.color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func byte(_ component: CGFloat) -> UInt8 {
            UInt8((min(1, max(0, component)) * 255).rounded())
        }

        // Settings range 1...20 (default 9) maps to 2.5%...9.2% of the video height (default ~5.3%).
        let size = Double(min(20, max(1, configuration.size)))

        return TextSubtitleStyle(
            fontName: configuration.fontName,
            fontHeightFraction: 0.025 + (size - 1) * 0.0035,
            color: SubtitleColor(red: byte(red), green: byte(green), blue: byte(blue), alpha: byte(alpha))
        )
    }
}
