# Release engineering

PermanentUnderclass distributes one macOS Apple silicon application archive
through GitHub Releases. There are no Intel, Linux, package-manager, or unsigned
release artifacts.

## Signing and notarization

The release workflow requires Developer ID signing with the hardened runtime,
Apple notarization, a stapled ticket, and a successful Gatekeeper assessment.
It fails before publishing if any of those checks fail. The five GitHub secrets
deliberately use the same names and formats as Little Control Room, so the same
Developer ID certificate and App Store Connect key can be configured here:

| Secret | Value |
| --- | --- |
| `MACOS_SIGN_P12` | Base64 contents of a Developer ID Application `.p12` certificate |
| `MACOS_SIGN_PASSWORD` | Password for the `.p12` |
| `MACOS_NOTARY_KEY` | Base64 contents of the App Store Connect API `.p8` key |
| `MACOS_NOTARY_KEY_ID` | App Store Connect API key ID |
| `MACOS_NOTARY_ISSUER_ID` | App Store Connect issuer UUID |

The credentials must be added to this repository before creating a release
tag. Source builds and CI snapshots use ad hoc signing and are never published.

## Archive contract

Every release contains:

- `PermanentUnderclass-macOS-arm64.zip`, containing
  `PermanentUnderclass.app`;
- `checksums.txt`, containing the archive's SHA-256 digest.

The executable and the archived copy are both checked to contain only the
`arm64` architecture. The app bundle includes the MIT license, the third-party
notice index, and every collected upstream license or notice.

## Local preflight

Before tagging, build and exercise the same archive shape without publishing:

```sh
swift test
PUNDERCLASS_ARCH=arm64 \
PUNDERCLASS_VERSION=0.1.0 \
PUNDERCLASS_BUILD_NUMBER=1 \
PUNDERCLASS_SIGNING_IDENTITY=- \
./scripts/build-app.sh release
./scripts/archive-release.sh 0.1.0
```

The local archive is ad hoc signed and is only a structural test. The tagged
GitHub workflow rebuilds it with Developer ID signing and performs notarization.

## Publishing

The workflow accepts stable semantic-version tags such as `v0.1.0`. Pushing the
tag runs tests on GitHub's native Apple silicon `macos-15` runner, imports the
certificate into an ephemeral keychain, builds, signs, notarizes, staples,
verifies, archives, and creates the GitHub Release. Do not create the tag until
the repository is ready for that external publication.

Unlike Little Control Room, PermanentUnderclass does not currently include an
automatic updater. GitHub Releases are the initial manual update channel. A
future Sparkle integration or Homebrew cask can consume the same notarized
archive without changing the signing pipeline.
