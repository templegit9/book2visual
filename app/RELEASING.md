# Releasing Book2Visual via Homebrew

End state — anyone on macOS Sonoma+ can install with a clean first launch (no
Gatekeeper warning, no right-click-Open, no DMG drag):

```sh
brew install --cask templegit9/tap/book2visual
```

This requires a **signed (Developer ID) + notarized + stapled** `.app`, hosted as
a zip on a GitHub release, with a Homebrew **cask** in the tap repo
`templegit9/homebrew-tap` pointing at it. `scripts/release.sh` does the whole
pipeline in one command.

> The older `scripts/package_release.sh` only ad-hoc signs the app (Gatekeeper
> will warn). Use `scripts/release.sh` for real distribution.

---

## One-time setup

You only do this section once per machine.

### 1. Developer ID Application certificate

Requires a paid Apple Developer Program membership ($99/yr). Create the cert in
Xcode:

> Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates → `+` →
> **Developer ID Application**

Verify it landed in your login keychain:

```sh
security find-identity -v -p codesigning
```

You want a line like:

```
1) 4CBAEA28... "Developer ID Application: Oluyinka Oginni (PVRL9W627Q)"
```

The full quoted string is your `DEVELOPER_ID`; the value in parentheses
(`PVRL9W627Q`) is your `TEAM_ID`.

### 2. App-specific password + notarytool keychain profile

`notarytool` cannot use your normal Apple ID password (2FA blocks it). Create an
**app-specific password**:

> <https://account.apple.com> → Sign-In and Security → App-Specific Passwords →
> `+` → name it e.g. "notarytool" → copy the generated `xxxx-xxxx-xxxx-xxxx`.

Store it once in a named keychain profile so the release script never sees the
raw password:

```sh
xcrun notarytool store-credentials "book2visual-notary" \
  --apple-id "you@example.com" \
  --team-id "PVRL9W627Q" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

`book2visual-notary` is the value you'll use for `AC_PROFILE`.

### 3. `.env.release` (gitignored — never commit)

Create `<repo-root>/.env.release` (one directory above `app/`):

```sh
DEVELOPER_ID="Developer ID Application: Oluyinka Oginni (PVRL9W627Q)"
TEAM_ID="PVRL9W627Q"
AC_PROFILE="book2visual-notary"
# optional:
# GH_REPO="templegit9/book2visual"
# TAP_CASK_FILE="$HOME/code/homebrew-tap/Casks/book2visual.rb"   # auto-push the cask
```

`.env.release` is already in `.gitignore`. Confirm:

```sh
git check-ignore .env.release   # should print: .env.release
```

### 4. Create the Homebrew tap repo (once)

The tap is a separate public GitHub repo named `homebrew-tap`. It lives
**outside** this app repo (never nest it inside — that creates a phantom
submodule):

```sh
gh repo create templegit9/homebrew-tap --public --clone --add-readme
mkdir -p homebrew-tap/Casks
cp Casks/book2visual.rb homebrew-tap/Casks/book2visual.rb
( cd homebrew-tap && git add Casks/book2visual.rb \
  && git commit -m "Add book2visual cask" && git push )
# move the clone somewhere stable, e.g. ~/code/homebrew-tap
```

`templegit9/homebrew-tap` + `Casks/book2visual.rb` is what makes
`templegit9/tap/book2visual` resolve.

### 5. GitHub CLI auth (once)

```sh
gh auth status   # must show: Logged in to github.com account templegit9
```

---

## Cutting a release

One command, from the repo root:

```sh
app/scripts/release.sh 1.0.1
```

It will:

1. `swift build -c release` and assemble `Book2Visual.app` with a concrete Info.plist
2. codesign with Developer ID + hardened runtime + the sandbox entitlements
3. `codesign --verify --strict` sanity check
4. zip with `ditto`, submit to `notarytool --wait`, and **verify the result is
   `Accepted`** (it dumps Apple's log and aborts if not)
5. `stapler staple` the ticket into the `.app`, then validate
6. **re-zip** (so the distributed zip contains the staple ticket)
7. compute sha256, create/update GitHub release `v1.0.1` with the zip
8. patch `version` + `sha256` into `Casks/book2visual.rb`

If you set `TAP_CASK_FILE` in `.env.release`, it also patches, commits and
pushes the cask in your tap clone. Otherwise the script prints the exact
copy/commit/push commands to finish.

### Publish the cask update (if not auto-pushed)

```sh
cp Casks/book2visual.rb ~/code/homebrew-tap/Casks/book2visual.rb
( cd ~/code/homebrew-tap && git add Casks/book2visual.rb \
  && git commit -m "book2visual 1.0.1" && git push )
```

### Verify the install end-to-end

```sh
brew untap templegit9/tap 2>/dev/null; brew tap templegit9/tap
brew install --cask templegit9/tap/book2visual
open -a Book2Visual          # should launch with no Gatekeeper prompt
```

---

## Version bumps

The version is the **argument** to `release.sh` — it flows into the Info.plist,
the zip name, the git tag (`v<version>`), the GitHub release, and the cask.
There is no version to edit in `project.yml` for a release. Start with a
pre-release (e.g. `0.1.0` / `1.0.1`) to validate the pipeline before claiming a
headline version.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `cert not found in keychain` at start | `DEVELOPER_ID` in `.env.release` must match `security find-identity -v -p codesigning` **character for character**, including the `(TEAMID)`. |
| `codesign --verify` fails | A nested bundle wasn't signed. This app is a single statically-linked SwiftPM binary, so the only nested items are SwiftPM resource `.bundle`s — the script signs those first. Inspect with `codesign -dvvv Book2Visual.app`. |
| notarytool status `Invalid` | The script auto-runs `xcrun notarytool log <id>`. Most common: a binary without hardened runtime, or signed with an expired/wrong cert, or missing secure timestamp. The script signs with `--options runtime --timestamp`, so re-check the cert. |
| `brew install` reports SHA mismatch | The cask in the tap is out of sync with the asset. Re-run `app/scripts/release.sh <same-version>` (it clobbers the asset and re-patches the cask), then re-push the tap. |
| Gatekeeper warning despite "Accepted" | The staple ticket didn't make it into the distributed zip. The script re-zips **after** stapling — confirm you're running `release.sh`, not `package_release.sh`. |
| `notarytool` hangs / very slow | Normal: Apple's notary takes 3–8 minutes. The `--wait` flag blocks until done. |
