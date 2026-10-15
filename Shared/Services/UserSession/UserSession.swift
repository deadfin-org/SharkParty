//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import JellyfinAPI
import Pulse

final class UserSession {

    let server: ServerState
    let user: UserState
    private(set) var configuration: UserSessionConfiguration
    private let isLifecycleTestSession: Bool

    @MainActor
    private(set) lazy var items = ItemStore()

    @MainActor
    var itemActionErrors = PassthroughSubject<Error, Never>()

    @MainActor
    var itemChanges: AnyCancellable?

    lazy var client: JellyfinClient = JellyfinClient(
        configuration: .swiftfinConfiguration(
            url: server.effectiveServerURL,
            accessToken: user.accessToken
        ),
        sessionConfiguration: .swiftfin,
        sessionDelegate: URLSessionProxyDelegate(logger: NetworkLogger.swiftfin())
    )

    @MainActor
    lazy var serverConnectionManager = ServerConnectionManager()

    lazy var serverSocketManager = ServerSocketManager()

    @MainActor
    private lazy var services: [any UserSessionService] = [
        serverConnectionManager,
        serverSocketManager,
    ]

    init(
        server: ServerState,
        user: UserState
    ) {
        self.server = server
        self.user = user
        configuration = UserSessionConfiguration(
            serverID: server.id,
            userID: user.id,
            serverURL: server.effectiveServerURL,
            accessToken: user.accessToken
        )
        isLifecycleTestSession = false
    }

    /// Allows a session lifecycle test to use a synthetic credential without
    /// writing to the device keychain.
    init(
        server: ServerState,
        user: UserState,
        configuration: UserSessionConfiguration
    ) {
        self.server = server
        self.user = user
        self.configuration = configuration
        isLifecycleTestSession = true
    }

    @MainActor
    func willStart() async {
        guard !isLifecycleTestSession else { return }

        observeItemChanges()
        for service in services {
            await service.willStart(userSession: self)
        }

        // Connection resolution during startup may select a different URL.
        configuration = UserSessionConfiguration(
            serverID: server.id,
            userID: user.id,
            serverURL: server.effectiveServerURL,
            accessToken: user.accessToken
        )
    }

    @MainActor
    func didStart() {
        guard !isLifecycleTestSession else { return }

        for service in services {
            service.didStart(userSession: self)
        }
    }

    @MainActor
    func willStop() {
        itemChanges = nil
        if !isLifecycleTestSession {
            for service in services.reversed() {
                service.willStop(userSession: self)
            }
        }

        items.invalidate()
        itemActionErrors.send(completion: .finished)
    }
}
