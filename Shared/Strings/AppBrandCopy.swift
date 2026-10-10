//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

enum AppBrandCopy {

    static var connectIntro: String {
        #if os(tvOS)
        L10n.sharkPartyConnectIntro
        #else
        L10n.connectToJellyfinServerStart
        #endif
    }

    static var quickConnectStep1: String {
        #if os(tvOS)
        L10n.sharkPartyQuickConnectStep1
        #else
        L10n.quickConnectStep1
        #endif
    }

    static var additionalSecurityAccessDescription: String {
        #if os(tvOS)
        L10n.sharkPartyAdditionalSecurityAccessDescription
        #else
        L10n.additionalSecurityAccessDescription
        #endif
    }

    static var customDeviceProfileAdd: String {
        #if os(tvOS)
        L10n.sharkPartyCustomDeviceProfileAdd
        #else
        L10n.customDeviceProfileAdd
        #endif
    }

    static var customDeviceProfileReplace: String {
        #if os(tvOS)
        L10n.sharkPartyCustomDeviceProfileReplace
        #else
        L10n.customDeviceProfileReplace
        #endif
    }

    static var metadataRefreshDescription: String {
        #if os(tvOS)
        L10n.sharkPartyMetadataRefreshDescription
        #else
        L10n.metadataRefreshDescription
        #endif
    }

    static var signoutCloseFooter: String {
        #if os(tvOS)
        L10n.sharkPartySignoutCloseFooter
        #else
        L10n.signoutCloseFooter
        #endif
    }

    static var signoutBackgroundFooter: String {
        #if os(tvOS)
        L10n.sharkPartySignoutBackgroundFooter
        #else
        L10n.signoutBackgroundFooter
        #endif
    }

    static func serverVersionWarning(_ version: String) -> String {
        #if os(tvOS)
        L10n.sharkPartyServerVersionWarning(version)
        #else
        L10n.serverVersionWarning(version)
        #endif
    }
}
