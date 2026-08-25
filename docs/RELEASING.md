# Releasing Betterlink

This doc covers cutting a release and the one-time setup behind it. The
pipeline lives in [`.github/workflows/release.yml`](../.github/workflows/release.yml)
— tag-driven, GitHub-Actions-hosted, no local steps once the secrets are in
place. The design is modeled on the Pacer project's release pipeline.

## Cutting a release (steady state)

1. Land your changes on `main`. The `CI` workflow (verify build) should be
   green.
2. Decide the version number (semver, `vX.Y.Z`).
3. Optionally write user-facing release notes at
   `docs/release-notes/X.Y.Z.md` — if present, that file becomes the GitHub
   Release body verbatim. Otherwise the workflow falls back to GitHub's
   generated notes, and if those are empty (work landed straight on main
   with no PRs), to the commit subjects since the previous tag.
4. Tag and push:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

5. Watch the `Release` workflow. It will:
   - Build a Release-configuration app.
   - Sign it with Developer ID + Hardened Runtime entitlements
     (`Sources/Betterlink/Betterlink.entitlements`).
   - Notarize and staple via the App Store Connect API.
   - Package a styled DMG with a drag-to-Applications affordance, then sign,
     notarize, and staple the DMG too.
   - Sign the DMG with the Sparkle EdDSA private key.
   - Publish the DMG as the asset on a GitHub Release named `vX.Y.Z`.
   - Append the new item to `appcast.xml` on the `gh-pages` branch.

6. Installed copies see the release on their next scheduled check (launch or
   every 24h) or immediately via Betterlink → "Check for Updates…".

Version numbers: the tag's `X.Y.Z` becomes `CFBundleShortVersionString`; the
workflow stamps `CFBundleVersion` with a unix timestamp so Sparkle's version
comparison (`sparkle:version`) is strictly monotonic per release run. The
values in `project.yml` (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) are
local-dev defaults only and are never committed back.

## One-time setup

Do this section once, before the first release.

### 1. Sparkle settings in `project.yml`

No placeholders remain. Both Sparkle values are set:

| Key | Value |
| --- | --- |
| `SUFeedURL` | `https://jfwoods.github.io/betterlink/appcast.xml` |
| `SUPublicEDKey` | `AYALH5595hYRQqHeF/qWLucgZSEVqXZC2REcOXbEN5A=` |

Both are baked into every build, and installed copies keep using the values
they shipped with. Changing either after the first release strands existing
users: a new feed URL means they poll a dead address, and a new public key
means they reject every update you sign. Treat both as permanent.

### 2. Apple Developer signing certificate

CI signs with a Developer ID Application certificate. Export yours as a
`.p12`:

1. Open **Keychain Access**.
2. Find `Developer ID Application: <Your Name> (<TEAMID>)` under the *login*
   keychain → My Certificates. (The workflow discovers the identity's full
   name from the imported certificate, so no Team ID configuration is
   needed.)
3. Right-click → Export → save as `signing.p12` with a strong password.
4. Base64-encode it for transit:

   ```sh
   base64 -i signing.p12 | pbcopy
   ```

5. The clipboard contents go into the `MACOS_CERTIFICATE` secret; the export
   password goes into `MACOS_CERTIFICATE_PASSWORD`.
6. Delete the local `.p12` when done.

### 3. App Store Connect API key (for notarization)

Interactive Apple-ID auth can't work in CI; notarization uses an API key:

1. App Store Connect → Users and Access → Integrations → App Store Connect
   API.
2. Create a new key with the `Developer` role.
3. Download the `.p8` file **immediately** — it is only offered once.
4. Note the **Key ID** (visible in the table) and the **Issuer ID** (top of
   the page).

The full contents of the `.p8` file (including the
`-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----` lines) go into
`NOTARY_KEY_P8`. The Key ID goes into `NOTARY_KEY_ID`, the Issuer ID into
`NOTARY_ISSUER_ID`.

### 4. Sparkle EdDSA keypair

Sparkle 2.x signs updates with Ed25519 so installed clients can verify each
download. The public key is embedded in the app's Info.plist; the private key
signs each release in CI.

**This keypair already exists.** The public key is in `project.yml` and the
private key is in the login keychain of the Mac that generated it. The steps
below are the record of how it was made and how to re-export the private key
if the CI secret is ever lost — not something to run again from scratch, which
would produce a different key and strand every installed copy.

1. Resolve the Sparkle SPM package locally once so the tools are on disk:

   ```sh
   xcodegen generate
   xcodebuild -resolvePackageDependencies -project Betterlink.xcodeproj
   ```

2. Find Sparkle's `generate_keys` binary (it ships prebuilt inside the SPM
   artifact bundle):

   ```sh
   find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path "*Sparkle*" | head -1
   ```

3. Generate a keypair. The first invocation stores the private key in the
   macOS Keychain and prints the matching public key:

   ```sh
   /path/to/generate_keys
   # → "A new key has been generated and saved in your keychain.
   #     Public key (SUPublicEDKey value): ABCDEF..."
   ```

4. Put the public key into `project.yml`, replacing the `SUPublicEDKey`
   placeholder. Commit.

5. Export the private key for CI use:

   ```sh
   /path/to/generate_keys -x sparkle-private.key
   ```

   Paste the contents of `sparkle-private.key` (a single line of base64
   text) into the `SPARKLE_ED_PRIVATE_KEY` secret. **Then delete the local
   file** — the only copies should be the Keychain entry on your Mac and the
   GitHub Actions secret.

   Do not rotate this keypair casually: clients installed against the old
   public key will refuse updates signed with a new private key, and you
   would have to shepherd every user through a manual re-download.

### 5. GitHub Pages (for the appcast)

The release workflow maintains `appcast.xml` at the root of the `gh-pages`
branch and constructs the feed URL from the repository name at run time.

**This step comes after the first release, not before it.** The Pages branch
picker only lists branches that exist, and `gh-pages` is created by the first
real release run (the `dry_run` path deliberately skips the appcast push). So:
tag `v0.1.0` first, let the workflow create the branch, then:

1. Repo Settings → Pages.
2. Source: **Deploy from a branch**.
3. Branch: **gh-pages** / root (`/`).
4. Save.

Then confirm `https://jfwoods.github.io/betterlink/appcast.xml` actually serves
the feed — it must match the `SUFeedURL` baked into the app. Pages takes a
minute or two to publish the first time.

Until Pages is switched on, `v0.1.0` is a working manual download and its
in-app update check fails quietly; nothing about the release needs redoing.

### 6. Set the GitHub Actions secrets

All secrets live under **Settings → Secrets and variables → Actions → New
repository secret** (or `gh secret set <NAME>`).

| Secret name | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of the Developer ID Application `.p12` (step 2) |
| `MACOS_CERTIFICATE_PASSWORD` | the password used when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any random string — only unlocks the ephemeral CI keychain (e.g. `openssl rand -base64 24`) |
| `NOTARY_KEY_ID` | App Store Connect API key ID (step 3) |
| `NOTARY_ISSUER_ID` | App Store Connect issuer UUID (step 3) |
| `NOTARY_KEY_P8` | full contents of the `.p8` file (step 3) |
| `SPARKLE_ED_PRIVATE_KEY` | exported Sparkle EdDSA private key (step 4) |

### 7. Smoke-test with workflow_dispatch

Before tagging the first real release, run the workflow manually with
`dry_run: true`:

1. Actions → Release → Run workflow.
2. Set `dry_run` to `true`. Click Run.

This exercises every step (signing, notarization, DMG, Sparkle signing)
*except* publishing the GitHub Release and pushing the appcast, so a broken
secret surfaces without polluting the update feed.

### Order for the very first release

1. Push `main`; let `CI` go green.
2. Run `Release` with `dry_run: true` (step 7) — proves the cert, the notary
   credentials, and the Sparkle signing all work.
3. Tag and push `v0.1.0`. This publishes the Release and creates `gh-pages`.
4. Turn on Pages (step 5) and check the appcast URL serves.

## Failure modes worth recognizing

- **No Developer ID Application identity found** — the `MACOS_CERTIFICATE`
  secret is malformed (likely a bad base64 paste) or the `.p12` doesn't
  contain the Developer ID cert. Re-export and re-encode.
- **Notarization `status: Invalid`** — read the log the workflow prints via
  `notarytool log`. Most common cause: a binary inside the bundle wasn't
  signed with Hardened Runtime (`--options runtime`). The release workflow
  signs Sparkle's components and any dylibs, but if a new bundled tool is
  added, extend the signing step in `release.yml`.
- **Sparkle update not detected** — check `appcast.xml` on `gh-pages`: it
  must list a `sparkle:version` greater than the installed
  `CFBundleVersion`. The workflow stamps that with a unix timestamp, so
  comparisons are strictly monotonic per release run.
- **`SUPublicEDKey` mismatch after rotating the keypair** — installed
  clients will refuse the new signature; publish a manual-download build to
  migrate them. Treat the private key like a code-signing cert.
- **Bad release shipped** — `appcast.xml` only ever grows; don't delete
  items. Tag a new patch release and let users update past it.
