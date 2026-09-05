# Releasing HushType

Repository: `Hanosn2007/HushType`. Always pass `--repo` to `gh`: this checkout also has an upstream remote with unrelated releases.

## Build and freeze

1. Increment both versions in `Resources/Info.plist`. Build numbers must strictly increase; 0.5.11 = 29, 0.5.14 = 32.
2. Install the test dependency (`brew install opencc`), run `swift test -c release --disable-sandbox`, then `make bundle BUNDLE_DIR=/path/to/fresh/HushType.app`. Never build over a running app. Alternatively use **Build release candidate** in Actions; it prepares Metal, tests and creates a Draft Release.
3. Archive once with `ditto -c -k --sequesterRsrc --keepParent /path/to/HushType.app HushType-VERSION.zip`. Independently extract and run `codesign --verify --deep --strict`. Confirm `mlx.metallib`, Sparkle and the expected version are present. Record SHA-256.
4. Test this exact ZIP. Do not rebuild or overwrite it after acceptance. The 0.5.14 archive is locally built. Actions is available for later releases; do not replace a tested archive with another build.

## Sign and publish

The EdDSA key is in the local login Keychain under account `com.felix.hushtype`; never copy it into CI, source control or release assets. Keep an offline backup.

In a dedicated directory containing only the exact release ZIP:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account com.felix.hushtype --maximum-deltas 0 \
  --download-url-prefix https://github.com/Hanosn2007/HushType/releases/download/v0.5.14/ \
  --link https://github.com/Hanosn2007/HushType/releases \
  -o /path/to/appcast.xml /path/to/archive-directory
swift scripts/verify_update.swift /path/to/appcast.xml /path/to/HushType-0.5.14.zip /Applications/HushType.app/Contents/Info.plist
```

The verifier uses the **installed old app's public key**, checks the archive signature, byte count, newer build, repository URL and minimum system. Verify an intentionally corrupted archive is rejected too. Preserve the old app's Info.plist for later checks after upgrading.

Publish the immutable ZIP to its GitHub Release before publishing the appcast. Download it back and compare SHA-256. Enable Pages once on `main` / `docs`. Publish `docs/appcast.xml` last and confirm HTTP 200 and exact contents. For the first end-to-end update, mark the Release prerelease until installation/relaunch checks complete; publishing its appcast nevertheless makes it available to existing clients.

## Acceptance and recovery

From 0.5.11 in `/Applications`, use Check for Updates → download → install and relaunch. Confirm the process comes from `/Applications`, version/build are 0.5.14/32, signature is valid, and a second check reports up to date. Human acceptance: F5, waveform, transcription, automatic paste, settings and another Mac (including macOS 27). Do not infer speech or visual correctness from build/HTTP checks.

Current builds are Apple Silicon, macOS 15+, ad-hoc signed and not notarized. Sparkle's EdDSA signature protects update archives but does **not** provide Developer ID identity continuity. After replacement, macOS may require microphone/Accessibility/PostEvent reauthorization; check the Permissions page and relaunch. If automatic paste is blocked, the text stays on the clipboard. For manual recovery, quit HushType, move the old app to Trash, install the verified ZIP's app into `/Applications`, then launch it there. Do not run transient ZIP/output copies. Model files and preferences are outside the app bundle.

Never lower a published build number or replace a release asset. A recovery build uses a higher build number. GitHub Releases remains the manual recovery path if automatic checks cannot connect.
