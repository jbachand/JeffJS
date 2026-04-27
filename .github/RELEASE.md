# Release pipeline

Two GitHub Actions workflows ship the JeffJS family to the App Store:

| Workflow | Trigger | What it does |
|---|---|---|
| `.github/workflows/testflight.yml` | manual (`workflow_dispatch`) | Builds the chosen platforms, uploads each binary to TestFlight |
| `.github/workflows/release.yml`    | manual (`workflow_dispatch`) | Submits the latest TestFlight build (matching the given version) for App Store review |

Build numbers are generated as the workflow's epoch start time (`date +%s`) so they're always strictly increasing and unique across runs.

## Required GitHub secrets

Set these under **Settings → Secrets and variables → Actions** on the repo. All seven are required for `testflight.yml`; `release.yml` only needs the three `APP_STORE_CONNECT_*` ones.

| Secret | What it is | How to get it |
|---|---|---|
| `APP_STORE_CONNECT_KEY_ID` | The 10-char Key ID for an App Store Connect API key | App Store Connect → **Users and Access → Integrations → App Store Connect API** → click **+** → role: **Admin** (or **App Manager**) → copy the *Key ID* |
| `APP_STORE_CONNECT_ISSUER_ID` | The team's Issuer UUID | Same page as above — shown at the top of the **Keys** tab |
| `APP_STORE_CONNECT_KEY_P8` | The `.p8` private key, **base64-encoded** | When you create the key, App Store Connect gives you a one-time `.p8` download. Then run: `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy` and paste the result. (You can only download the key once — keep a copy somewhere safe.) |
| `BUILD_CERTIFICATE_BASE64` | Apple Distribution `.p12` certificate, base64-encoded | In Xcode, **Settings → Accounts → Manage Certificates**. If you don't have an "Apple Distribution" cert, click **+** → **Apple Distribution**. Then in **Keychain Access**, find it under *login → My Certificates*, right-click → **Export**, save as `.p12` with a password, then `base64 -i AppleDistribution.p12 \| pbcopy` |
| `BUILD_CERTIFICATE_PASSWORD` | Password you set when exporting the `.p12` | Whatever you typed during export above |
| `KEYCHAIN_PASSWORD` | Any password — used for the temporary keychain CI creates | Generate a random one (e.g. `openssl rand -base64 32`) |

> **Tip:** the `.p8`, `.p12` and the team_id `3F45D8TQ28` are all that change between users. The Issuer ID is per Apple Developer team. The Key ID is per API key.

## Bundle identifiers

These are baked into `JeffJSConsole/fastlane/Appfile` and `Fastfile`:

- `ai.hudson.JeffJSConsole` — Console (iOS / iPadOS / macOS / visionOS, all the same bundle ID)
- `ai.hudson.JeffJS` — watchOS container app
- `ai.hudson.JeffJS.watchkitapp` — Watch app inside the container
- `ai.hudson.JeffJS.watchkitapp.JeffJS-Watch-Widget` — Watch widget extension

Each bundle ID **must already exist** on App Store Connect, with the matching app records created in **My Apps**, before the pipeline can upload to it.

## Triggering a TestFlight build

1. Go to **Actions → TestFlight → Run workflow**.
2. Enter:
   - **Marketing version** — e.g. `1.0.1`. This will be written into `MARKETING_VERSION` of the Xcode project for the build.
   - **Platforms** — `all` (default) or a single one.
3. Run. Each platform runs in its own parallel job. When all jobs go green:
   - The binaries are uploaded to TestFlight.
   - App Store Connect needs ~10–30 min to finish processing.
   - You'll see them under **TestFlight → iOS Builds / macOS Builds / visionOS Builds / watchOS Builds**.

The pipeline does **not** auto-submit for external testing or review — you can still QA internally first.

## Submitting for App Store review

After the TestFlight build is in **Ready to Submit** state and you've finalized metadata + screenshots in App Store Connect:

1. Go to **Actions → Submit for App Store Review → Run workflow**.
2. Enter the same **Marketing version** you uploaded.
3. Pick platforms.
4. Run.

Each job calls `upload_to_app_store` (Fastlane `deliver`) with `submit_for_review: true`, `automatic_release: true`. The build is submitted; once Apple approves it, it auto-releases.

The release workflow does **not** upload metadata or screenshots — manage those in App Store Connect directly. (If you want this workflow to push metadata too, drop the `skip_metadata: true` / `skip_screenshots: true` flags in `Fastfile` and add `fastlane/metadata/` and `fastlane/screenshots/` directories.)

## Local testing

```bash
cd JeffJSConsole
bundle install
VERSION=1.0.1 bundle exec fastlane ios beta
```

Locally you can also use a logged-in Xcode for auth (skip the API-key env vars) — `fastlane spaceauth -u your@apple.id` if 2FA is in the way.
