//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Captures the inputs used to restore a session. Comparing stored models alone
/// misses changes to the keychain token and active server connection.
struct UserSessionConfiguration: Equatable {

    let serverID: String
    let userID: String
    let serverURL: URL
    let accessToken: String
}
