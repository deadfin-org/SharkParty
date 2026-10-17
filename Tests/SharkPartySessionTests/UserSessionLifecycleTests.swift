//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import Foundation
@testable import SharkParty
import XCTest

final class UserSessionLifecycleTests: XCTestCase {

    @MainActor
    func testSurvivingViewModelRebindsAfterRepeatedSessionReplacements() async throws {
        let first = makeSession()
        let unchangedRestore = UserSession(
            server: first.server,
            user: first.user,
            configuration: first.configuration
        )
        let second = makeSession()
        let third = makeSession()

        let manager = UserSessionManager()
        Container.shared.userSessionManager.register { manager }
        Container.shared.currentUserSession.reset()
        let viewModel = ViewModel()

        await manager.applyCurrentSession(first)
        XCTAssertTrue(try viewModel.requireUserSession() === first)

        // An unchanged foreground refresh keeps the original store active.
        await manager.applyCurrentSession(unchangedRestore)
        XCTAssertTrue(manager.currentSession === first)
        XCTAssertTrue(try viewModel.requireUserSession() === first)
        XCTAssertNoThrow(try first.items.validate())

        await manager.applyCurrentSession(second)
        XCTAssertFalse(first.items.isActive)
        XCTAssertTrue(try viewModel.requireUserSession() === second)
        XCTAssertNoThrow(try second.items.validate())

        await manager.applyCurrentSession(third)
        XCTAssertFalse(second.items.isActive)
        XCTAssertTrue(try viewModel.requireUserSession() === third)
        XCTAssertNoThrow(try third.items.validate())

        await manager.applyCurrentSession(nil)
        Container.shared.userSessionManager.reset()
        Container.shared.currentUserSession.reset()
    }

    @MainActor
    func testHomeRetriesWithReplacementSessionWhenLoadStartedOnOldSession() async {
        let first = makeSession()
        let second = makeSession()

        let manager = UserSessionManager()
        Container.shared.userSessionManager.register { manager }
        Container.shared.currentUserSession.reset()
        await manager.applyCurrentSession(first)

        // The first load starts on the old session and the session changes before it completes.
        let probe = SessionProbe()
        probe.beforeValidate = {
            if probe.sessions.count == 1 {
                await manager.applyCurrentSession(second)
            }
        }
        let viewModel = ContentGroupViewModel(provider: SessionProbeProvider(probe: probe))

        await viewModel.refresh()

        XCTAssertEqual(viewModel.state, .content)
        XCTAssertNil(viewModel.error)
        XCTAssertEqual(probe.sessions.map(ObjectIdentifier.init), [first, second].map(ObjectIdentifier.init))

        await manager.applyCurrentSession(nil)
        Container.shared.userSessionManager.reset()
        Container.shared.currentUserSession.reset()
    }

    @MainActor
    func testLoadedHomeRebuildsGroupsAfterSessionReplacement() async throws {
        let first = makeSession()
        let second = makeSession()

        let manager = UserSessionManager()
        Container.shared.userSessionManager.register { manager }
        Container.shared.currentUserSession.reset()
        await manager.applyCurrentSession(first)

        let probe = SessionProbe()
        let viewModel = ContentGroupViewModel(provider: SessionProbeProvider(probe: probe))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.state, .content)

        await manager.applyCurrentSession(second)

        // The rebuild is scheduled after a short coalescing delay
        let deadline = Date.now.addingTimeInterval(5)
        while probe.sessions.count < 2, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(probe.sessions.map(ObjectIdentifier.init), [first, second].map(ObjectIdentifier.init))
        XCTAssertEqual(viewModel.state, .content)
        XCTAssertNil(viewModel.error)

        await manager.applyCurrentSession(nil)
        Container.shared.userSessionManager.reset()
        Container.shared.currentUserSession.reset()
    }

    private func makeSession() -> UserSession {
        let serverID = UUID().uuidString
        let userID = UUID().uuidString
        let url = URL(string: "https://media.example.test")!
        let server = ServerState(urls: [url], currentURL: url, name: "Test", id: serverID, userIDs: [userID])
        let user = UserState(id: userID, serverID: serverID, username: "Test")
        let configuration = UserSessionConfiguration(serverID: serverID, userID: userID, serverURL: url, accessToken: "synthetic")
        return UserSession(server: server, user: user, configuration: configuration)
    }
}

/// Records which session each Home load used
@MainActor
private final class SessionProbe {

    var sessions: [UserSession] = []
    var beforeValidate: @MainActor () async -> Void = {}
}

/// Resolves the current session the same way as the Home provider
private struct SessionProbeProvider: ContentGroupProvider {

    let displayTitle = "Probe"
    let id = "session-probe"
    let probe: SessionProbe

    @MainActor
    func makeGroups(environment: Empty) async throws -> [any ContentGroup] {
        guard let session = Container.shared.currentUserSession() else { return [] }

        probe.sessions.append(session)
        await probe.beforeValidate()
        try session.items.validate()

        return []
    }
}
