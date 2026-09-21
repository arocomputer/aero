# Contributing to Aero

Aero is a small, fast macOS browser built on the system's WebKit. Good contributions
solve a concrete browsing need, keep the app small, and leave the code easy to
understand and verify. Explain why a change needs a new dependency, setting, or
abstraction before adding one.

## Getting set up

```sh
git clone https://github.com/arocomputer/aero
cd aero
./x hooks
(cd Website && npm ci)    # only to work on the site
./x dev
```

Aero needs macOS 15.4 or newer and a Swift 6 toolchain. The Command Line Tools are enough.
Install Python 3 for repository tooling and Node.js 22 or newer for the website.

`./x dev` is the everyday loop: a debug build, a few seconds against the release bundle's
fourteen, with its own browsing data and the Web Inspector on, opened in the background so
it does not take over your screen. `./x run` builds and starts Aero as it ships, which is how
to meet a change the way someone using the browser would; `./x app` is that build on its own. Read [AGENTS.md](AGENTS.md) for the code map, the log channels, focused test
commands, and app boundaries. These rules apply to people and agents alike.

## Commit checks

Run `./x hooks` once in each contributing checkout or worktree. Setup preserves an
existing executable pre-commit hook and refuses to silently disable other hooks. It
configures only this worktree's hook path.

The hook checks staged whitespace, conflict markers, and Swift formatting. It reads the
staged files, leaves unstaged edits alone, and never rewrites or stages content. Builds
and tests remain separate. CI runs the repository guard and the same checks on the
committed diff, so local hooks are not the only verification.

## Reporting issues

Use the [bug or feature forms](https://github.com/arocomputer/aero/issues/new/choose).
A bug report needs steps, expected and actual behavior, and the affected version or
commit. For a page that misbehaves, give a public address and say whether Safari does
the same; Aero uses the same engine, and a problem Safari shares is WebKit's. For slow or
uneven scrolling, include the Mac model, the display and its scaling, and the pointing
device.

Feature requests should start with what you are trying to do. Aero stays small, so
explain why the feature belongs in it.

Report security-sensitive findings privately using [SECURITY.md](SECURITY.md). Never
paste private addresses, history, page content, or unreviewed logs.

## Before opening a PR

```sh
./x check                                  # quality, tests, and the website when it is installed
./x shot https://example.com shot.png      # a picture of the change, with no window on screen
```

Run `./x check` for every submission. It skips the website checks unless `Website/`'s
packages are installed, which matches how CI splits them; install them and run
`./x website check` when you touch the site. Every pull request reports two required results.
Changes to `Website/`, its workflow, or `x` also report `Website / Website Check`.

| Required check | Local command | Coverage |
| --- | --- | --- |
| Validate | `./x quality` | Swift formatting, a build with warnings as errors, the repository guard, and hook tests |
| Build and Test | `./x test`, `./x app` | Unit tests, the release bundle, its signature, and its icon |

GitHub displays workflow and job names together. The results appear as
`Quality / Validate` and `App / Build and Test`.

A regression test must fail on the original defect. Keep tests focused on the types
that hold rules. Views have no tests, so include a picture when appearance or motion
changes: `./x shot` takes one from a real window without raising anything on your desktop,
and a recording is still the better evidence for motion. Do not weaken an assertion to
make a regression pass. Update comments and guides with code changes.

Include the setup and before and after measurements when claiming a speed improvement.
Aero has no performance budgets or benchmark CI gate. Do not commit benchmark code; it
belongs in the PR description.

## Review

Use a short branch such as `fix/strip-highlight`. PR titles use conventional commits,
for example `fix(omnibox): keep the field still when tabs open quickly`. Optional scopes
are `strip`, `omnibox`, `tab`, `page`, `history`, `infra` and `docs`. The title should
make sense as a squash commit on main.

Use the [PR template](.github/pull_request_template.md). Link a related issue when one
exists, select the change type, explain the problem and why the change works, and list
verification commands and results. Write enough detail to review the change without a
fixed sentence limit.

Keep each PR about one coherent change; leave unrelated cleanup for another
contribution. Do not promise compatibility or performance that has not been checked.

PRs do not use labels. Change types belong in the title and template, not automatic
path-based or dependency labels. Issues can still use labels.

The maintainer decides whether a change merges. [CODEOWNERS](.github/CODEOWNERS) calls
out navigation, the in-page script, address handling, the manifest, and automation for
review; it does not by itself configure branch protection. Passing checks are evidence
for review, not permission to merge or release.

## AI/LLM assistance

AI-assisted issues and pull requests are welcome when the contributor owns the result
and can explain it.

- Review generated code, tests, prose, and commit messages before requesting review.
- Do not attribute commits to AI/LLM tools as author, co-author, committer, or
  signatory. Do not add `Assisted-by`, AI `Co-authored-by`, or model/harness footers.
- Answer maintainer questions yourself. Generated text is input to your response, not a
  substitute for understanding the change.
- Keep one AI-assisted pull request open at a time.

If you cannot explain or maintain the proposed change, revise or close the submission
rather than passing that responsibility to reviewers.

## Documentation

The README introduces the app. Root markdown files describe repository policy. A folder gets a
README of its own only when several files work together and no single file owns that story;
`Sources/Page/` and `Website/` have one, and nothing else needs one. Keep one authoritative
account of each rule; use Git history for past decisions.

## Releases

Aero is in development and has made no release. Commits and pull requests do not
authorize one. `./x app` signs ad hoc, which is enough to run the app on the Mac that
built it and not enough to give anyone else; a release needs a Developer ID signature
and notarization first.

`./x signed-app` retains the existing distribution-signing entry point. It requires
`AERO_SIGNING_IDENTITY`, `AERO_PROVISIONING_PROFILE` and `AERO_UPDATE_PUBLIC_KEY`, embeds the profile, signs with
hardened runtime and a timestamp, and verifies the signature. This path has not been
verified with publisher credentials. After Apple approves the capabilities and a profile is available:

```sh
security find-identity -v -p codesigning
AERO_SIGNING_IDENTITY='Developer ID Application: …' \
  AERO_PROVISIONING_PROFILE=/path/to/Aero.provisionprofile \
  AERO_UPDATE_PUBLIC_KEY='public Ed25519 key' ./x signed-app
```

`./x app` signs ad hoc with App Sandbox and hardened runtime using `Sandbox.entitlements`.
Local ad hoc builds additionally disable library validation because they have no signing team to
share with Sparkle. This exception is absent from Developer ID builds. `Scripts/sparkle.py` embeds
the pinned framework and signs its helpers before the enclosing bundle.
`./x signed-app` also embeds the profile and adds the managed browser entitlements in
`Aero.entitlements`, then verifies the resulting signature. Ad hoc builds do not claim
capabilities that Apple has not granted. The profile must cover the browser, passkey and DNS-settings
entitlements requested by `Aero.entitlements`. `./x notarize-app` signs, submits with the
`AERO_NOTARY_PROFILE` keychain profile, then staples and validates the accepted ticket.
Only after validation succeeds does it create or replace `build/Aero.zip` from the stapled app.
Use that ZIP for distribution. `build/Aero-notarization.zip` is the earlier submission archive
and does not contain the stapled ticket. No command publishes a release.

`container-migration.plist` moves the current bundle identity's existing browser data into the
sandbox on first launch. Test migration with a disposable bundle identity and fixture data, never
by deleting a person's browser container. Custom download folders use security-scoped bookmarks;
folders chosen before sandboxing may need to be selected again.

Refresh the bundled tracker domains with `python3 Scripts/trackers.py`, review the diff and run
`./x check`. The list's attribution and redistribution permission ship in `TrackerListNotice.txt`.
App updates use Sparkle with signed feeds and verification before archive extraction. The sole
package exception is pinned in `Package.swift` and `Package.resolved`; changing it also requires
updating the guard. The framework license is copied into the app's resources when packaging.

Create the update-signing key once with `.build/artifacts/sparkle/Sparkle/bin/generate_keys`.
The tool stores the private key in the login Keychain and prints its public key. Supply only that
public key as `AERO_UPDATE_PUBLIC_KEY`. Keep signing keys out of chat, source files and Git.
Builds without the public key do not start update checks. `./x dev` always omits it, even
when the environment supplies a publisher key, so the dev app cannot install production updates.

After release authorization, run `./x notarize-app` with the signing variables above and
`AERO_NOTARY_PROFILE` set. Copy its `build/Aero.zip` into the release archives directory under a
unique filename containing the build version before creating another build. Each newer build must
have a higher `CFBundleVersion`. Keep the submission ZIP out of this directory. Run
`AERO_UPDATE_DOWNLOAD_PREFIX=https://…/ ./x update-feed /path/to/archives`. Publish the generated
signed appcast at the bundle's `SUFeedURL`, together with its signed notes and archives. Never edit
a signed feed without regenerating its signature. Use a real older and newer signed build to test
installation and relaunch before distributing updates.

`./x protection-feed` signs the reviewed tracker list using the same Keychain key. Publish the
generated `Trackers.txt` and `Trackers.txt.sig` at the bundle's `BrowserProtectionListURL` and its
`.sig` companion. The app rejects bad signatures, malformed lists and older list versions. Failed
checks keep the last working list. These publishing commands are maintainer release operations.

After the maintainer explicitly authorizes a release:

1. Choose the version and update `CFBundleShortVersionString` and `CFBundleVersion` in
   `Info.plist`.
2. Run `./x check` on the release commit, on a Mac with Xcode so the icon compiles with
   all its looks, then `./x run` and try the app.
3. Sign with the Developer ID certificate and notarize the bundle. Never place
   credentials in chat or Git.
4. Push `v<version>` and draft the GitHub release with the notarized archive, using the
   format below.

Never release from a pull request or weaken tag protection to do so.

## Release notes

[GitHub Releases](https://github.com/arocomputer/aero/releases) are the published history.
Write a short release title and introduction, followed by these groups in order. Omit
empty groups.

```markdown
### Release title

A short explanation of the changes that matter to people using Aero.

### New features
- Describe the new capability and how to reach it.

### Improvements
- Describe what got better, with the measurement when it is about speed.

### Fixes
- **Security:** Describe security fixes before other fixes.
```

Use concrete behavior, not commit subjects or implementation inventories. The release
tag provides the version and GitHub supplies the publication date.

## License

Contributions are released under the repository's [MIT license](LICENSE).
