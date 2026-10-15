//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

/// The subtitle elements visible at one moment.
public struct SubtitleFrame: Sendable {

    /// Changes whenever the set of visible cues changes; animated cues still need per-tick placement.
    public let key: [Int]
    /// Back to front.
    public let subtitles: [RenderedSubtitle]

    public static let empty = SubtitleFrame(key: [], subtitles: [])
}

/// Resolves which cues are visible at a media time and rasterizes them, caching images.
/// Thread-safe: the presenter may prerender on a background queue while querying on the main thread.
public final class SubtitleRenderer: @unchecked Sendable {

    public let track: SubtitleTrack
    public let fonts: SubtitleFontProvider

    private let lock = NSLock()
    private var cache: [Int: [RenderedSubtitle]] = [:]
    private var cacheCanvas: CGSize = .zero
    /// Vertical displacement applied by collision handling, kept while a cue stays visible.
    private var stackOffsets: [Int: CGFloat] = [:]

    /// Text cue indexes bucketed by whole second for quick lookup.
    private let buckets: [Int: [Int]]
    private var cacheBytes = 0
    private static let maxCachedEntries = 256
    private static let maxPrerender = 128
    /// Rasterized cues at 4K can be several megabytes each; keep the cache modest on Apple TV.
    private static let cacheByteBudget = 48 * 1024 * 1024

    public init(track: SubtitleTrack, fonts: SubtitleFontProvider = SubtitleFontProvider()) {
        self.track = track
        self.fonts = fonts

        var buckets: [Int: [Int]] = [:]
        if case let .text(script) = track {
            for (index, event) in script.events.enumerated() {
                let first = Int(floor(max(0, event.start)))
                let last = Int(floor(max(0, event.end)))
                guard last - first < 6 * 3600 else { continue }

                for second in first ... last {
                    buckets[second, default: []].append(index)
                }
            }
        }
        self.buckets = buckets
    }

    /// Identifiers of cues visible at `time`, in drawing order (layer, then file order).
    public func activeIDs(at time: Double) -> [Int] {
        switch track {
        case let .text(script):
            guard time >= 0 else { return [] }

            let candidates = buckets[Int(floor(time))] ?? []
            return candidates
                .filter { script.events[$0].start <= time && time < script.events[$0].end }
                .sorted {
                    let lhs = script.events[$0]
                    let rhs = script.events[$1]
                    return (lhs.layer, lhs.readOrder) < (rhs.layer, rhs.readOrder)
                }

        case let .bitmap(track):
            guard let composition = track.composition(at: time) else { return [] }

            return [composition.id]
        }
    }

    /// The next time after `time` at which the visible set may change; `nil` when nothing follows.
    public func nextChange(after time: Double) -> Double? {
        switch track {
        case let .text(script):
            var next: Double?
            for event in script.events {
                if event.start > time {
                    next = min(next ?? event.start, event.start)
                }
                if event.end > time {
                    next = min(next ?? event.end, event.end)
                }
            }
            return next

        case let .bitmap(track):
            if let composition = track.compositions.first(where: { $0.start > time }) {
                return composition.start
            }
            return nil
        }
    }

    /// Visible cues at `time` rendered for `canvasSize` (text) with collision handling applied.
    public func frame(at time: Double, canvasSize: CGSize) -> SubtitleFrame {
        let ids = activeIDs(at: time)
        guard !ids.isEmpty else {
            lock.withLock { stackOffsets.removeAll() }
            return .empty
        }

        let rendered = ids.flatMap { render(id: $0, canvasSize: canvasSize) }
        let placed = lock.withLock { resolveCollisions(rendered, activeIDs: Set(ids)) }
        return SubtitleFrame(key: ids, subtitles: placed)
    }

    /// Whether every cue in `ids` is already rasterized for `canvasSize`, so `frame(at:canvasSize:)`
    /// returns without drawing.
    public func isRendered(_ ids: [Int], canvasSize: CGSize) -> Bool {
        guard !ids.isEmpty else { return true }

        let key = cacheKey(canvasSize)
        return lock.withLock {
            cacheCanvas == key && ids.allSatisfy { cache[$0] != nil }
        }
    }

    /// Renders cues starting within `window` seconds after `time`, soonest first, so they are ready when needed.
    public func prerender(after time: Double, window: Double, canvasSize: CGSize) {
        let upcoming: [Int] = switch track {
        case let .text(script):
            script.events
                .indices
                .filter { script.events[$0].start >= time && script.events[$0].start < time + window }
                .sorted { script.events[$0].start < script.events[$1].start }

        case let .bitmap(track):
            track.compositions
                .filter { $0.start >= time && $0.start < time + window }
                .map(\.id)
        }

        for id in upcoming.prefix(Self.maxPrerender) {
            _ = render(id: id, canvasSize: canvasSize)
        }
    }

    public func render(id: Int, canvasSize: CGSize) -> [RenderedSubtitle] {
        let key = cacheKey(canvasSize)

        if let cached = lock.withLock({ () -> [RenderedSubtitle]? in
            if cacheCanvas != key {
                cache.removeAll()
                cacheBytes = 0
                cacheCanvas = key
            }
            return cache[id]
        }) {
            return cached
        }

        let rendered: [RenderedSubtitle]
        switch track {
        case let .text(script):
            guard script.events.indices.contains(id) else { return [] }

            rendered = ASSTextRenderer.render(
                event: script.events[id],
                script: script,
                canvasSize: canvasSize,
                fonts: fonts
            )
            .map { [$0] } ?? []

        case let .bitmap(track):
            guard track.compositions.indices.contains(id) else { return [] }

            rendered = Self.render(composition: track.compositions[id], videoSize: track.videoSize)
        }

        lock.withLock {
            guard cacheCanvas == key else { return }

            cache[id] = rendered
            cacheBytes += Self.byteCount(rendered)

            // Evict the cues furthest in time from this one; playback is mostly sequential. File order is
            // no guide: typeset scripts often keep signs and dialogue in separate blocks.
            if cacheBytes > Self.cacheByteBudget || cache.count > Self.maxCachedEntries {
                let anchor = startTime(of: id)
                let victims = cache.keys.sorted { abs(startTime(of: $0) - anchor) > abs(startTime(of: $1) - anchor) }
                for victim in victims where victim != id {
                    guard cacheBytes > Self.cacheByteBudget / 2 || cache.count > Self.maxCachedEntries / 2 else { break }

                    cacheBytes -= cache.removeValue(forKey: victim).map(Self.byteCount) ?? 0
                }
            }
        }
        return rendered
    }

    /// Drops cached images and stacking state (seek, canvas change, memory pressure).
    public func reset() {
        lock.withLock {
            cache.removeAll()
            cacheBytes = 0
            stackOffsets.removeAll()
        }
    }

    private func cacheKey(_ canvasSize: CGSize) -> CGSize {
        switch track {
        case .text:
            CGSize(width: canvasSize.width.rounded(), height: canvasSize.height.rounded())
        case .bitmap:
            // PGS images do not depend on the presentation size.
            .zero
        }
    }

    private func startTime(of id: Int) -> Double {
        switch track {
        case let .text(script):
            script.events.indices.contains(id) ? script.events[id].start : 0
        case let .bitmap(track):
            track.compositions.indices.contains(id) ? track.compositions[id].start : 0
        }
    }

    private static func byteCount(_ subtitles: [RenderedSubtitle]) -> Int {
        subtitles.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
    }

    static func render(composition: PGSComposition, videoSize: CGSize) -> [RenderedSubtitle] {
        composition.objects.enumerated().compactMap { index, placed in
            guard let image = PGSDecoder.image(for: placed, palette: composition.palette) else { return nil }

            let frame = CGRect(x: placed.x, y: placed.y, width: image.width, height: image.height)
            return RenderedSubtitle(
                id: composition.id << 8 | index,
                image: image,
                frame: frame,
                padding: 0,
                canvasSize: videoSize,
                layer: 0,
                readOrder: index,
                start: composition.start,
                end: composition.end,
                stacking: .none,
                motion: nil,
                rotation: 0,
                rotationPivot: .zero
            )
        }
    }

    /// Bottom-aligned cues stack upward and top-aligned cues stack downward when they overlap others
    /// on the same layer. Cues already on screen keep their place; newcomers move around them.
    private func resolveCollisions(_ subtitles: [RenderedSubtitle], activeIDs: Set<Int>) -> [RenderedSubtitle] {
        stackOffsets = stackOffsets.filter { activeIDs.contains($0.key) }

        var placedByLayer: [Int: [CGRect]] = [:]
        var result: [Int: RenderedSubtitle] = [:]

        for subtitle in subtitles where subtitle.stacking == .none {
            result[subtitle.id] = subtitle
            placedByLayer[subtitle.layer, default: []].append(subtitle.contentFrame)
        }

        let stackable = subtitles.filter { $0.stacking != .none }
        let ordered = stackable.filter { stackOffsets[$0.id] != nil } + stackable.filter { stackOffsets[$0.id] == nil }

        for subtitle in ordered {
            var moved = subtitle
            let placed = placedByLayer[subtitle.layer] ?? []

            if let offset = stackOffsets[subtitle.id] {
                moved.frame.origin.y += offset
            } else {
                var attempts = 0
                while let blocker = placed.first(where: { $0.insetBy(dx: 1, dy: 1).intersects(moved.contentFrame) }), attempts < 32 {
                    switch subtitle.stacking {
                    case .up:
                        moved.frame.origin.y = blocker.minY - moved.frame.height + moved.padding
                    case .down:
                        moved.frame.origin.y = blocker.maxY - moved.padding
                    case .none:
                        break
                    }
                    attempts += 1
                }
                stackOffsets[subtitle.id] = moved.frame.origin.y - subtitle.frame.origin.y
            }

            result[subtitle.id] = moved
            placedByLayer[subtitle.layer, default: []].append(moved.contentFrame)
        }

        return subtitles.compactMap { result[$0.id] }
    }
}
