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
