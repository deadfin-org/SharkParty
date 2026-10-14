<p align="center">
  <img src="Design/sharkparty-logo.png" alt="SharkParty" width="128" height="128">
</p>

<h1 align="center">SharkParty</h1>

<p align="center">
  <strong>An Apple TV client for Deadfin and Jellyfin.</strong><br>
  A tvOS fork of Swiftfin.
</p>

<p align="center">
  <a href="LICENSE.md"><img alt="License: MPL-2.0" src="https://img.shields.io/badge/license-MPL--2.0-blue"></a>
  <img alt="tvOS 26.1+" src="https://img.shields.io/badge/tvOS-26.1%2B-black">
  <img alt="Jellyfin API 12.0" src="https://img.shields.io/badge/Jellyfin%20API-12.0-9962be">
</p>

---

SharkParty is a media client for Apple TV. It is a fork of
[Swiftfin](https://github.com/jellyfin/Swiftfin), the Jellyfin client for iOS
and tvOS. It speaks the Jellyfin API, so it connects to
[Deadfin](https://github.com/deadfin-org/deadfin) and to stock Jellyfin
servers.

## What it is

- **Swiftfin for tvOS, with its own identity.** SharkParty is the Swiftfin
  tvOS app under the name SharkParty, with bundle ID
  `org.deadfin.SharkParty`, its own icon and top shelf art, and the
  `sharkparty` URL scheme.
- **Installs next to Swiftfin.** SharkParty keeps its servers, accounts,
  settings and keychain entries apart from Swiftfin's. Both apps can be on the
  same Apple TV. SharkParty does not import Swiftfin's saved servers or
  accounts.
- **Server-neutral wording.** The tvOS sign-in and settings screens name
  Deadfin and Jellyfin as supported servers.
- **Swiftfin's players.** Playback uses Swiftfin's two players: VLC (through
  SwiftVLC) and Native (AVPlayer). See [players.md](Documentation/players.md)
  for what each supports.

The Swiftfin iOS target is still in the project and keeps its upstream
identity. SharkParty is the tvOS app only.

## Upstream base

SharkParty starts from Swiftfin `main` at commit
[`7d778734`](https://github.com/jellyfin/Swiftfin/commit/7d778734a9dce3e37b593c3c54f4dfb5a140e28b)
(2026-10-09). That revision is 155 commits ahead of the Swiftfin 1.6.1
release and includes Swiftfin's newer player stack. The full Swiftfin history
is kept in this repository.

## Status: pre-alpha

SharkParty is early. It builds and runs in the tvOS 27 Simulator, and
sign-in, library browsing, artwork and movie playback work there against
Deadfin. It has not been verified on a physical Apple TV yet.

There are no TestFlight or App Store builds. To run it, build it from
source.

## Requirements

- An Apple TV running tvOS 26.1 or later.
- A Deadfin or Jellyfin 12.0 server.
- To build: a Mac with Xcode 27.0 and the tvOS 27 SDK.

## Build from source

You need:

- Xcode 27.0 with the tvOS 27.0 SDK and Simulator runtime
- [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) and
  [SwiftLint](https://github.com/realm/SwiftLint). The Xcode build runs
  SwiftFormat on the tree. Install both with Homebrew:

  ```bash
  brew bundle --file Brewfile
  ```

Xcode resolves the Swift packages when you open `Swiftfin.xcodeproj`. If a
package fails to resolve, reset the package caches in Xcode
(File → Packages → Reset Package Caches) and try again.

### Simulator

Open `Swiftfin.xcodeproj`, choose the **SharkParty tvOS** scheme and an Apple
TV simulator, and run. From the command line:

```bash
xcodebuild -project Swiftfin.xcodeproj -scheme 'SharkParty tvOS' \
  -configuration Debug -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Pass the destination as shown. Do not add `-sdk appletvsimulator`: it builds
the Swift macro plugin for the wrong platform.

### Apple TV

Installing on an Apple TV needs an Apple developer team for signing.

1. Create `XcodeConfig/DevelopmentTeam.xcconfig` with your team ID. Git
   ignores this file.

   ```
   DEVELOPMENT_TEAM = YOURTEAMID
   ```

2. In the **SharkParty tvOS** target's Signing & Capabilities, set a bundle
   identifier that your team can register, for example
   `com.example.SharkParty`.
3. Pair the Apple TV with Xcode (Window → Devices and Simulators), select it
   as the run destination, and run the **SharkParty tvOS** scheme.

Apple's guide covers device pairing and signing:
[Running your app in Simulator or on a device](https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device/).

### Checks

Before you open a pull request, run SwiftLint and the macro package tests:

```bash
swiftlint lint --strict --config .swiftlint.yml
swift test --package-path SwiftfinMacros
```

## Documentation

- [Branding and app data](Documentation/branding.md): the tvOS identity,
  where SharkParty stores its data, and how the icons are generated.
- [Players](Documentation/players.md) and
  [library support](Documentation/libraries.md), from Swiftfin.
- [Common issues](Documentation/common_issues.md), from Swiftfin.

## Translations

SharkParty uses Swiftfin's translations. Strings added by SharkParty are in
English and show in English in other languages until they are translated.

## Provenance

SharkParty is a fork of Swiftfin with full upstream history. SharkParty's
changes are written with AI coding agents and reviewed by its maintainer.
Swiftfin's copyright notices and license are kept.

## License

SharkParty is licensed under the Mozilla Public License 2.0 (`MPL-2.0`), the
same license as Swiftfin. See [LICENSE.md](LICENSE.md). The Swift packages it
uses are under their own licenses.

## Security

Report security problems privately through
[GitHub security advisories](https://github.com/deadfin-org/deadfin/security/advisories/new)
on the Deadfin repository. Do not open a public issue for a security problem.

## Issues and questions

Report bugs and client problems in the
[Deadfin issue tracker](https://github.com/deadfin-org/deadfin/issues). Ask
questions in [Deadfin discussions](https://github.com/deadfin-org/deadfin/discussions).
Include the SharkParty commit, the tvOS version and the server you use.

Problems that also happen in Swiftfin belong upstream, in the
[Swiftfin issue tracker](https://github.com/jellyfin/Swiftfin/issues).

## Acknowledgements

SharkParty exists because of [Swiftfin](https://github.com/jellyfin/Swiftfin)
and its [contributors](https://github.com/jellyfin/Swiftfin/graphs/contributors),
who built the app this fork runs on, and [Jellyfin](https://jellyfin.org),
whose API it speaks. Thanks also to the translators on Jellyfin's
[Weblate](https://translate.jellyfin.org/projects/swiftfin/) and the authors
of the Swift packages Swiftfin depends on. Thank you.

SharkParty is not affiliated with or endorsed by the Jellyfin or Swiftfin
projects. Jellyfin is a trademark of its respective owners.
