# Namu TODO

## Release Pipeline — Secrets Setup

The release pipeline is built and ready. Add these secrets in **GitHub repo Settings > Secrets and variables > Actions** to enable full signed releases.

| Secret | Purpose | How to get |
|--------|---------|------------|
| `APPLE_CERTIFICATE_BASE64` | Code signing cert (.p12, base64-encoded) | Export from Keychain Access: "Developer ID Application" cert > Export > .p12 > `base64 -i cert.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the .p12 file | Set during export |
| `APPLE_SIGNING_IDENTITY` | Signing identity string | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Apple ID email | Your Apple Developer account email |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization | Generate at [appleid.apple.com](https://appleid.apple.com/account/manage) > App-Specific Passwords |
| `APPLE_TEAM_ID` | 10-character team ID | Find at [developer.apple.com/account](https://developer.apple.com/account) > Membership |
| `SPARKLE_PRIVATE_KEY` | Ed25519 private key for Sparkle update signing | Generate: `openssl genpkey -algorithm ed25519 -outform DER \| base64` |
| `HOMEBREW_TAP_TOKEN` | GitHub PAT with repo access to `namu-sh/homebrew-namu` | Create at [github.com/settings/tokens](https://github.com/settings/tokens) with `repo` scope |

### First Release Checklist

- [ ] Add all secrets above to GitHub
- [ ] Generate Sparkle key pair and add private key as secret
- [ ] Set `CFBundleShortVersionString` in Xcode to `0.1.0`
- [ ] Tag and push: `git tag v0.1.0 && git push origin v0.1.0`
- [ ] Verify release workflow completes
- [ ] Verify DMG downloads and installs
- [ ] Verify `brew tap namu-sh/namu && brew install --cask namu` works
- [ ] Verify Sparkle auto-update check works in-app

## Backlog

### Terminal
- [ ] Investigate cursor position lag (Ghostty rendering — pre-existing)
- [ ] Bundle Ghostty themes in app resources (currently relies on `~/.config/ghostty/themes/`)

### Sidebar
- [ ] Left rail color strip for workspace custom colors (alongside shell state dot)
- [ ] Tooltip/popover for detailed workspace info (PRs, status pills, metadata, logs)

### Notifications
- [ ] Per-panel attention ring indicator in split view
- [ ] Notification sound per workspace

### Session Persistence
- [ ] Display geometry remapping for multi-monitor (window position validation on restore)
- [ ] Persist sidebar metadata (status entries, log entries) across restarts
