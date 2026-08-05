# Release Scripts

## `release.sh` — Ship a new version of makesomething

Automates the full release pipeline: build → sign → DMG → notarize → Sparkle appcast → GitHub Release.

### Quick start

```bash
# Auto-bumps version and build number from the latest GitHub Release
./scripts/release.sh
```

The script checks GitHub for the latest release (e.g. `v1.5`, build 6) and automatically bumps to `v1.6`, build 7. You'll see a confirmation prompt before anything runs.

### Override version or build

```bash
# Set a specific marketing version (auto-bumps build)
./scripts/release.sh 2.0

# Set both marketing version and build number
./scripts/release.sh 2.0 10
```

### Safety

- **Duplicate detection**: If the tag already exists on GitHub, the script exits with an error and suggests what to do.
- **Confirmation prompt**: Shows the version, build, and previous release before proceeding. Press `y` to continue.

### What it does

1. Fetches the latest release from GitHub to determine version + build
2. Archives the app via `xcodebuild`
3. Exports a signed `.app` with Developer ID
4. Creates a DMG with the drag-to-Applications background
5. Notarizes the DMG with Apple (Gatekeeper compliance)
6. Signs the DMG with the Sparkle EdDSA key
7. Generates `appcast.xml` for Sparkle auto-updates
8. Creates a GitHub Release with the DMG attached
9. Pushes the updated `appcast.xml` to the releases repo

### One-time setup (prerequisites)

1. **Xcode** with your Developer ID signing certificate
2. **Homebrew tools**:
   ```bash
   brew install create-dmg gh
   ```
3. **GitHub CLI auth**:
   ```bash
   gh auth login
   ```
4. **Apple notarization credentials** (stored in Keychain):
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
       --apple-id YOUR_APPLE_ID \
       --team-id YOUR_TEAM_ID
   ```
   You'll be prompted for an app-specific password (generate one at [appleid.apple.com](https://appleid.apple.com)).
5. **Sparkle EdDSA key** — already generated and stored in Keychain (done during initial Sparkle setup)
6. **Build the project in Xcode at least once** so SPM downloads Sparkle and the Sparkle CLI tools are available

## post-commit-autopush.sh

Canonical copy of the git `post-commit` hook that auto-pushes every commit to
origin in the background, so GitHub stays a current backup and work never
piles up unpushed.

Git does not track `.git/hooks/`, so the live hook is invisible to version
control — a fresh clone silently has no auto-push and nothing indicates it is
missing. This file is the tracked copy. Keep the two in sync; if you edit one,
copy it over the other.

Install (or reinstall after a fresh clone):

```bash
cp scripts/post-commit-autopush.sh .git/hooks/post-commit
chmod +x .git/hooks/post-commit
```

Verify it is live:

```bash
.git/hooks/post-commit && sleep 5 && tail -3 /tmp/clicky_autopush.log
# expect: "post-commit push: main" then "Everything up-to-date"
```

Failures log to `/tmp/clicky_autopush.log` and never block or fail the commit.

Concurrency: pushes are serialized with a `mkdir` mutex at
`/tmp/clicky_autopush.lock`. Before this (fixed 2026-08-05) rapid commits fired
overlapping background pushes and GitHub rejected the losers with
`cannot lock ref 'refs/heads/main'`, leaving commits unpushed while the hook
reported nothing wrong. Do NOT switch the lock release to an EXIT trap — on
macOS bash an EXIT trap set inside a backgrounded `{ ... } &` subshell does not
fire, which leaks the lock and wedges every later push.
