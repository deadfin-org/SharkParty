//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Foundation
import JellyfinAPI
import Network
@testable import SharkParty
import XCTest

/// Plays and stops the AVPlayer proxy several times against a loopback HLS server.
/// A stopped item must release its player resources and stop fetching segments.
final class AVPlayerProxyLifecycleTests: XCTestCase {

    private var server: LoopbackHLSServer!

    override func setUpWithError() throws {
        server = try LoopbackHLSServer()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    @MainActor
    func testStopReleasesItemAndPlayer() async throws {
        let cycles = 4
        var releasedProxies: [WeakBox<AVMediaPlayerProxy>] = []
        var releasedPlayers: [WeakBox<AVPlayer>] = []
        var releasedItems: [WeakBox<AVPlayerItem>] = []

        for cycle in 0 ..< cycles {
            var proxy: AVMediaPlayerProxy? = AVMediaPlayerProxy()
            let url = try server.playlistURL(session: "cycle\(cycle)")

            proxy?.playNew(item: makeItem(url: url, session: "cycle\(cycle)"))
            let playerItem = try XCTUnwrap(proxy?.player.currentItem)

            try await waitUntil("cycle \(cycle): a segment request") {
                self.server.segmentRequests(session: "cycle\(cycle)") > 0
            }

            // Alternate the two stop paths: the manager's stop and the view's stopped state.
            if cycle.isMultiple(of: 2) {
                proxy?.stop()
            } else {
                proxy?.playbackStopped()
            }

            XCTAssertNil(proxy?.player.currentItem, "cycle \(cycle): the player still has an item after stop")

            releasedProxies.append(WeakBox(proxy))
            releasedPlayers.append(WeakBox(proxy?.player))
            releasedItems.append(WeakBox(playerItem))
            proxy = nil
        }

        try await waitUntil("all proxies, players, and items released") {
            releasedProxies.allSatisfy { $0.value == nil }
                && releasedPlayers.allSatisfy { $0.value == nil }
                && releasedItems.allSatisfy { $0.value == nil }
        }
    }

    @MainActor
    func testStoppedItemFetchesNoMoreSegments() async throws {
        let proxy = AVMediaPlayerProxy()

        for cycle in 0 ..< 3 {
            let session = "fetch\(cycle)"
            try proxy.playNew(item: makeItem(url: server.playlistURL(session: session), session: session))

            try await waitUntil("\(session): a segment request") {
                self.server.segmentRequests(session: session) > 0
            }

            proxy.stop()

            try await waitUntil("\(session): the client closes its segment connections") {
                self.server.openSegmentConnections(session: session) == 0
            }

            let requestsAfterStop = server.segmentRequests(session: session)
            try await Task.sleep(for: .seconds(2))

            XCTAssertEqual(
                server.segmentRequests(session: session),
                requestsAfterStop,
                "\(session): segment requests continued after stop"
            )
            XCTAssertEqual(server.openSegmentConnections(session: session), 0)
        }

        proxy.playbackStopped()
    }

    // MARK: - Helpers

    @MainActor
    private func makeItem(url: URL, session: String) -> MediaPlayerItem {
        MediaPlayerItem(
            baseItem: .init(id: session, name: session),
            mediaSource: .init(id: session),
            playSessionID: session,
            url: url,
            deviceProfile: .init()
        )
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description)")
                return
            }

            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private struct WeakBox<Value: AnyObject> {

    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

/// A minimal HTTP/1.1 server on the loopback interface.
///
/// `/<session>/index.m3u8` is a VOD playlist. Each `/<session>/seg<N>.ts` sends MPEG-TS null
/// packets slowly and never finishes, so the connection stays open while the client wants data.
private final class LoopbackHLSServer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "org.deadfin.SharkParty.tests.loopback-hls")
    private let listener: NWListener
    private var port: NWEndpoint.Port = .any

    /// Guarded by `queue`.
    private var segmentRequestCounts: [String: Int] = [:]
    /// Guarded by `queue`.
    private var openSegments: [ObjectIdentifier: (session: String, timer: DispatchSourceTimer)] = [:]
    /// Guarded by `queue`.
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }

        self.port = port
    }

    func playlistURL(session: String) throws -> URL {
        try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/\(session)/index.m3u8"))
    }

    func segmentRequests(session: String) -> Int {
        queue.sync { segmentRequestCounts[session, default: 0] }
    }

    func openSegmentConnections(session: String) -> Int {
        queue.sync { openSegments.values.count(where: { $0.session == session }) }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections.values {
                connection.cancel()
            }
            for segment in openSegments.values {
                segment.timer.cancel()
            }
            connections.removeAll()
            openSegments.removeAll()
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(id)
            default: ()
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func close(_ id: ObjectIdentifier) {
        if let segment = openSegments.removeValue(forKey: id) {
            segment.timer.cancel()
        }
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            if let data { buffer.append(data) }

            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let rest = Data(buffer[end.upperBound...])
                let path = head.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"

                respond(to: path, on: connection)
                if openSegments[ObjectIdentifier(connection)] == nil {
                    receiveRequest(on: connection, buffer: rest)
                } else {
                    watchForClose(connection)
                }
                return
            }

            if isComplete || error != nil {
                close(ObjectIdentifier(connection))
                return
            }

            receiveRequest(on: connection, buffer: buffer)
        }
    }

    /// The client closes the connection to abandon a segment download.
    private func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] _, _, isComplete, error in
            guard let self else { return }

            if isComplete || error != nil {
                close(ObjectIdentifier(connection))
            } else {
                watchForClose(connection)
            }
        }
    }

    private func respond(to path: String, on connection: NWConnection) {
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 2 else {
            send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", on: connection)
            return
        }

        let session = components[0]
        let resource = components[1]

        if resource == "index.m3u8" {
            var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            for index in 0 ..< 50 {
                playlist += "#EXTINF:6.0,\nseg\(index).ts\n"
            }
            playlist += "#EXT-X-ENDLIST\n"

            let body = Data(playlist.utf8)
            send(
                "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\n\r\n",
                body: body,
                on: connection
            )
        } else if resource.hasPrefix("seg"), resource.hasSuffix(".ts") {
            segmentRequestCounts[session, default: 0] += 1
            send("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: 100000000\r\n\r\n", on: connection)
            trickleSegment(session: session, on: connection)
        } else {
            send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", on: connection)
        }
    }

    private func trickleSegment(session: String, on connection: NWConnection) {
        // Ten MPEG-TS null packets (PID 0x1FFF): valid transport stream with no content.
        var packet = Data([0x47, 0x1F, 0xFF, 0x10])
        packet.append(Data(repeating: 0xFF, count: 184))
        let chunk = Data((0 ..< 10).flatMap { _ in packet })

        let id = ObjectIdentifier(connection)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard self?.openSegments[id] != nil else { return }

            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil {
                    self?.close(id)
                }
            })
        }
        openSegments[id] = (session, timer)
        timer.resume()
    }

    private func send(_ head: String, body: Data = Data(), on connection: NWConnection) {
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
