# Releasing HushType

Repository: `Hanosn2007/HushType`. Always pass `--repo` to `gh`: this checkout also has an upstream remote with unrelated releases.

## Build and freeze

1. Increment both versions in `Resources/Info.plist`. Build numbers must strictly increase; 0.5.16 = 34, 0.5.17-rc.1 = 35, 0.5.17 = 36.
2. Install the test dependency (`brew install opencc`), run `swift test -c release --disable-sandbox`, then `make bundle-stable BUNDLE_DIR=/path/to/fresh/HushType.app`. Never build over a running app. `bundle-stable` requires the fixed local certificate and never falls back to ad-hoc signing. The **Build release candidate** workflow also requires this identity; hosted runners currently lack it and stop before building. Use the local release path until secure CI provisioning is explicitly arranged.
3. Archive once with `ditto -c -k --sequesterRsrc --keepParent /path/to/HushType.app HushType-VERSION.zip`. Independently extract and run `codesign --verify --deep --strict`. Confirm `mlx.metallib`, Sparkle and the expected version are present. Record SHA-256.
4. Test this exact ZIP. Do not rebuild or overwrite it after acceptance. Release archives are locally built with the pinned identity. Do not replace a tested archive with another build.

## Stable self-signed code identity

The 0.5.16 line remains ad-hoc signed. The 0.5.17 release sequence migrates to the pinned self-signed certificate; do not replace 0.5.16 or its assets. All later releases must retain this certificate and designated requirement so macOS can recognize the updated app as the same identity.

Use only the pre-created local certificate and its exact SHA-1 fingerprint; never select an identity by its display name:

```sh
security find-identity -v -p codesigning
make bundle-stable BUNDLE_DIR=/path/to/fresh/HushType.app
```

The signing script sets this designated requirement and rejects missing, malformed, or ambiguous identity input:

```
identifier "com.felix.hushtype" and certificate leaf = H"SHA1_FINGERPRINT"
```

After making a certificate-signed baseline and a later, distinct certificate-signed bundle, verify them before any manual replacement:

```sh
bash scripts/verify_signing_continuity.sh /path/to/old/HushType.app /path/to/new/HushType.app
```

The continuity checker rejects an ad-hoc old bundle by design, requires different CDHashes, checks both bundle IDs, checks both signatures with `--deep --strict`, and verifies that each bundle satisfies the other's designated requirement. It does not prove TCC continuity. Sparkle's local update validator verifies the EdDSA archive signature and requires a valid new code signature; it does not require the old and new apps to share a designated requirement. Keep the existing EdDSA signing flow unchanged. On 2026-09-06, a separate test application using this certificate retained microphone and Accessibility authorization after a different binary replaced it, then retained both plus PostEvent after a real Sparkle 3→4 download/install/relaunch. The installed files matched the signed update artifact. This validates the mechanism on this Mac, not yet migration of the actual HushType app or other macOS versions. The actual HushType ad-hoc→certificate transition still needs one fresh authorization and update acceptance. Sparkle's shipped nested signatures are preserved; the signing script does not use `--deep` to re-sign them.

## Signing identity continuity and recovery

`scripts/release-signing.sha1` pins the public fingerprint. The private key is in the maintainer's login Keychain; it was generated in memory, not written to this repository. The public certificate is stored locally under `~/Library/Application Support/HushType/Signing/`. Do not generate a replacement identity when switching computers: restore the original certificate **and private key**. Missing identity must fail packaging. Do not install the signing private key on end-user computers.

On 2026-09-06, both the application signing identity (encrypted PKCS#12) and the separate Sparkle EdDSA private key were backed up together under AES-256-GCM encryption in a separate private GitHub repository, as explicitly authorized by the maintainer. The random decryption credential is stored only in the login Keychain under label `HushType GitHub backup decryption key` (service `HushType Signing Backup`). No plaintext signing key or decryption credential was committed. Remote download/decryption and both signing checks passed; import into an isolated empty Keychain, rereading and signing also passed.

The maintainer plans a one-time Time Machine backup and login-Keychain migration **when changing computers**, not ongoing backups. No Time Machine run or schedule was started. Before retiring the old Mac, restore the login Keychain and verify the encrypted backup on the new Mac using its recovery README. The repository alone cannot decrypt the backup if both the login Keychain and its backup are lost. This does not claim that cross-machine migration has already been tested.

## Sign and publish

The EdDSA key is in the local login Keychain under account `com.felix.hushtype`; never copy it into CI, source control or release assets. Keep an offline backup.

In a dedicated directory containing only the exact release ZIP:

```sh
release_version=0.5.17 # Use 0.5.17-rc.1 for the migration candidate.
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account com.felix.hushtype --maximum-deltas 0 \
  --download-url-prefix "https://github.com/Hanosn2007/HushType/releases/download/v${release_version}/" \
  --link https://github.com/Hanosn2007/HushType/releases \
  -o /path/to/appcast.xml /path/to/archive-directory
swift scripts/verify_update.swift /path/to/appcast.xml "/path/to/HushType-${release_version}.zip" /path/to/saved-old-Info.plist
```

The verifier uses the **installed old app's public key**, checks the archive signature, byte count, newer build, repository URL and minimum system. Verify an intentionally corrupted archive is rejected too. Preserve the old app's Info.plist for later checks after upgrading.

Publish the immutable ZIP to its GitHub Release before publishing the appcast. Download it back and compare SHA-256. Enable Pages once on `main` / `docs`. Publish `docs/appcast.xml` last and confirm HTTP 200 and exact contents. For the first end-to-end update, mark the Release prerelease until installation/relaunch checks complete; publishing its appcast nevertheless makes it available to existing clients.

## Acceptance and recovery

From the current installed release in `/Applications`, use Check for Updates → download → install and relaunch. Close settings and confirm the same process remains running; reopen settings and check both update entrypoints. Confirm the process comes from `/Applications`, version/build are 0.5.17/36, signature is valid, and a second check reports up to date. Human acceptance: F5, waveform, transcription, automatic paste, settings and another Mac (including macOS 27). Do not infer speech or visual correctness from build/HTTP checks.

Current builds are Apple Silicon, macOS 15+, signed with the pinned self-signed identity and not notarized. Sparkle's EdDSA signature protects update archives; the pinned application certificate and designated requirement provide the separate code identity. Migration from the old ad-hoc identity is expected to require microphone/Accessibility/PostEvent reauthorization once; check the Permissions page and relaunch. Later updates must preserve that identity, and the actual app update path must be verified. If automatic paste is blocked, the text stays on the clipboard. For manual recovery, quit HushType, move the old app to Trash, install the verified ZIP's app into `/Applications`, then launch it there. Do not run transient ZIP/output copies. Model files and preferences are outside the app bundle.

Never lower a published build number or replace a release asset. A recovery build uses a higher build number. GitHub Releases remains the manual recovery path if automatic checks cannot connect.
