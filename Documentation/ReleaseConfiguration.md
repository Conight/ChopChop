# Release configuration

Edit [`Configuration/Release.xcconfig`](../Configuration/Release.xcconfig) to configure an independent distribution. It contains public values only:

| Setting | Purpose |
| --- | --- |
| `CHOPCHOP_RELEASE_REPOSITORY` | GitHub `owner/repository` for release checks, release pages, update manifests, DMGs, help and issue links |
| `CHOPCHOP_APP_IDENTIFIER` | Application identity; also derives the installer service, sandbox container permission, queue document type and local signing Keychain service |
| `CHOPCHOP_UPDATE_PUBLIC_KEY` | Base64-encoded 32-byte Ed25519 public key used to authenticate updates |

Xcode's project configurations inherit this file directly. Both the application and its XPC installer embed these values in their signed `Info.plist`. Runtime code reads those bundled values, never an environment variable or a downloaded release response. Missing or invalid configuration cannot silently fall back to the original repository.

Keep these settings as unique literal assignments, with optional whole-line `//` comments. The release scripts validate this deliberately small format; includes and conditional assignments are not supported. The public-key writer inserts Xcode’s empty `$()` substitution after slashes because Xcode treats `//` as a comment, even inside quotes. Other substitutions are not supported. Private keys must never be added here.

## Community contributions and local builds

Cloning, editing, testing and compiling the application requires no production private key. Keep the existing configuration when submitting changes to the original project. The normal verification scripts use disposable keys for updater fixtures.

## Publishing an independent fork

1. Change the repository and choose a unique reverse-DNS app identifier in the configuration file. The identifier gives the fork its own settings, sandbox data and Keychain signing entry. Keep the current public key value temporarily so the configuration remains syntactically valid during key creation.
2. Run `Scripts/update-signing.sh create-key`. It creates or reads the key under `<CHOPCHOP_APP_IDENTIFIER>.update-signing` and prints only its public half. Run `python3 Scripts/release_config.py --set-public-key 'PUBLIC_KEY'` with that output to write `CHOPCHOP_UPDATE_PUBLIC_KEY` safely before building the fork for distribution.
3. Export the private key with `Scripts/update-signing.sh export-key /absolute/private/temporary-file`. Supply that file to the fork repository's `CHOPCHOP_UPDATE_PRIVATE_KEY` Actions secret, then remove the temporary export. Keep a secure private backup. A separate public Actions variable is unnecessary.
4. Run `python3 Scripts/release_config.py --check-repository OWNER/REPOSITORY` and `Scripts/verify.sh`. Set the app version and increment its build number in Xcode as usual, add English release notes, and push an annotated version tag when ready to publish.

The release workflow refuses a mismatched repository. Signing refuses an app whose embedded configuration differs from this file or whose public key does not match the private signing key. App updates also reject a different bundle identifier, public key or release repository during installation.

The application/product name and asset convention remain `ChopChop.app`, `ChopChop-v<VERSION>-macos-arm64.dmg` and `ChopChop-v<VERSION>-update.json`; branding and additional architectures are separate changes. The workflow still needs a runner matching its `xcode-27` label. The private secret is required only for publishing signed updates, not for pull-request validation or local builds.

Users manually install the fork once, then receive updates from its configured repository. Changing an established app identifier or signing key creates a separate identity or trust chain; this configuration refactor does not migrate existing user data or implement key rotation. The original distribution's values remain unchanged.

## Isolated signing fixtures

`Scripts/update-signing.sh --configuration PATH.xcconfig COMMAND ...` and `Scripts/sign-update-dmg.sh DMG OUTPUT_JSON --configuration PATH.xcconfig` accept an explicit fixture configuration. The updater integration test uses this to sign temporary fork applications without reading or changing the production Keychain key.
