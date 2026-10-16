# Security policy

## Report a vulnerability

Report security problems privately through GitHub private vulnerability
reporting on the Deadfin repository:

<https://github.com/deadfin-org/deadfin/security/advisories/new>

Put "SharkParty" in the title. The report is private to the maintainers.
Include:

- The SharkParty commit or build, the tvOS version, and the Apple TV model
  or simulator.
- The server and its version (Deadfin or Jellyfin).
- What an attacker can do, and what they need first (network position, an
  account, physical access to the Apple TV).
- Steps that show the problem.
- Placeholders in place of real tokens, passwords, and API keys.

Do not open a public issue for a security problem.

## Supported versions

SharkParty is pre-alpha software. Security fixes go to `main`.

## Scope

This policy covers the SharkParty tvOS app in this repository. Report
problems in the Deadfin server under the
[Deadfin security policy](https://github.com/deadfin-org/deadfin/blob/master/SECURITY.md).
Report problems in upstream Swiftfin code, Jellyfin, or the Swift packages
the app uses to their upstream projects.
