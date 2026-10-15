//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

let current = UserSessionConfiguration(
    serverID: "server-a",
    userID: "user-a",
    serverURL: URL(string: "https://media.example.test")!,
    accessToken: "token-a"
)

let restored = UserSessionConfiguration(
    serverID: "server-a",
    userID: "user-a",
    serverURL: URL(string: "https://media.example.test")!,
    accessToken: "token-a"
)
precondition(current == restored, "Foreground restoration must preserve the active session")

let replacements: [UserSessionConfiguration] = [
    .init(serverID: "server-b", userID: current.userID, serverURL: current.serverURL, accessToken: current.accessToken),
    .init(serverID: current.serverID, userID: "user-b", serverURL: current.serverURL, accessToken: current.accessToken),
    .init(
        serverID: current.serverID,
        userID: current.userID,
        serverURL: URL(string: "https://backup.example.test")!,
        accessToken: current.accessToken
    ),
    .init(serverID: current.serverID, userID: current.userID, serverURL: current.serverURL, accessToken: "token-b"),
]

for replacement in replacements {
    precondition(current != replacement, "A changed session configuration must be replaced")
}

print("Session configuration regression checks passed")
