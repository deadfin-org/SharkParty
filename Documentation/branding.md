# SharkParty tvOS branding

The tvOS target and shared scheme are named **SharkParty tvOS**. Its display name and executable are **SharkParty**, and its bundle ID is `org.deadfin.SharkParty`. The iOS target remains Swiftfin while its release plan is undecided. The Xcode project and upstream package names stay as technical references. The fork retains upstream copyright notices and MPL-2.0.

The tvOS icon and top shelf artwork are generated from the approved `Design/sharkparty-logo.png` without changing the shark drawing. To regenerate after an intentional asset layout change, run `swift Scripts/generate-sharkparty-assets.swift` from the repository root. The script writes fixed size icon layers, a shared in-app logo, and top shelf banners. It does not edit the source PNG.

tvOS data is separate from Swiftfin: the app's bundle ID gives it a different sandbox and default keychain access group; the keychain keys also have a SharkParty prefix. Its defaults suites use `sharkpartyApp` and per-user names beginning `sharkparty-user-`, and its SQLite store is named `SharkParty.sqlite`. The tvOS target has no app group entitlement. There is no automatic migration of Swiftfin's saved servers, accounts, or settings. The tvOS URL scheme is `sharkparty`; the deep-link parser accepts it alongside upstream schemes for the iOS target.

Signing, physical Apple TV installation, and the iOS product identity are later decisions. This branding change does not alter playback or server behavior.
The upstream TestFlight workflow still carries its Swiftfin signing and bundle assumptions; it requires a separate release decision before tvOS use.

## Interface wording

The tvOS onboarding prompt asks for a media server and names Deadfin and Jellyfin as supported servers. Quick Connect refers to the server's web app. Shared settings, security, device-profile, and metadata messages use server-neutral or SharkParty wording on tvOS. The version warning identifies the Jellyfin compatibility check used by the client. The default accent color is labeled “Default.” The upstream iOS copy remains intact. Jellyfin and Swiftfin names remain where they identify an API, SDK, protocol, upstream project, source/license, or iOS-only feature.

New tvOS copy has English source strings and falls back to English in other locales until translations are reviewed. Existing translations remain untouched to avoid inaccurate machine edits across 56 locales.

## Simulator verification

On the M2 Max with Xcode 27.0 and tvOS Simulator 27.0, `xcodebuild` completed the unsigned `SharkParty tvOS` Debug build. The built `Info.plist` reported `org.deadfin.SharkParty`, display name `SharkParty`, and URL scheme `sharkparty`. In the existing tvOS simulator, both Swiftfin and SharkParty were installed with different bundle IDs and data container paths. SharkParty launched to the Connect screen. The [running app](sharkparty-simulator.png) and [both app icons](sharkparty-coexistence.png) were captured from the simulator. No account credentials were entered; server connections, saved entries, and physical Apple TV installation remain untested.
