//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

extension SelectUserView {

    struct ConnectToServerIntroView: View {

        @Default(.accentColor)
        private var accentColor

        @Router
        private var router

        var body: some View {
            VStack {
                Text(AppBrandCopy.connectIntro)
                    .multilineTextAlignment(.center)

                #if os(tvOS)
                Text(L10n.sharkPartySupportedServers)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                #endif

                Button {
                    router.route(to: .connectToServer)
                } label: {
                    Text(L10n.connect)
                        .frame(maxWidth: .infinity)
                }
                .fontWeight(.semibold)
                .backport
                .buttonStyle(.glassProminent.shadow(false))
                .tint(accentColor)
                #if os(iOS)
                    .controlSize(.large)
                #endif
                    .frame(
                        height: UIDevice.isTV ? 75 : 44
                    )
            }
            .frame(maxWidth: UIDevice.isTV ? 400 : 250)
        }
    }
}
