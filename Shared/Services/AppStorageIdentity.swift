//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

enum AppStorageIdentity {

    #if os(tvOS)
    static let appOwnerID = "sharkpartyApp"
    static let databaseName = "SharkParty.sqlite"
    static let debugSuiteName = "sharkparty-debug-defaults"
    #else
    static let appOwnerID = "swiftfinApp"
    static let databaseName = "Swiftfin.sqlite"
    static let debugSuiteName = "swiftfinstore-debug-defaults"
    #endif

    static func userSuiteName(for id: String) -> String {
        #if os(tvOS)
        "sharkparty-user-\(id)"
        #else
        id
        #endif
    }
}
