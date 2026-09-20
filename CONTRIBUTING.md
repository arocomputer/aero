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
(cd Website && npm ci)
./x run
```

Aero needs macOS 15.4 or newer and a Swift 6 toolchain. The Command Line Tools are enough.
Install Python 3 for repository tooling and Node.js 22 or newer for the website.
Contributors using the managed `~/Code`
collection should follow its README and use a worktree.

Read [AGENTS.md](AGENTS.md) for the code map, focused test commands, and app
boundaries. These rules apply to people and agents alike.

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
./x check    # check the native app and website
./x run      # build the app and look at the change
```

Run `./x check` for every submission. Every pull request reports two required results.
Changes to `Website/`, its workflow, or `x` also report `Website / Website Check`.

| Required check | Local command | Coverage |
| --- | --- | --- |
| Validate | `./x quality` | Swift formatting, a build with warnings as errors, the repository guard, and hook tests |
| Build and Test | `./x test`, `./x app` | Unit tests, the release bundle, its signature, and its icon |

GitHub displays workflow and job names together. The results appear as
`Quality / Validate` and `App / Build and Test`.

A regression test must fail on the original defect. Keep tests focused on the types
that hold rules. Views have no tests, so include a screenshot or recording when
appearance or motion changes. Do not weaken an assertion to make a regression pass.
Update comments and guides with code changes.

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

The README introduces the app. Root markdown files describe repository policy. Keep one
authoritative account of each rule; use Git history for past decisions.

## Releases

Aero is in development and has made no release. Commits and pull requests do not
authorize one. Builds are signed ad hoc, which is enough to run locally and not enough
to distribute; a release needs a Developer ID signature and notarization first.

After Apple approves Aero's managed browser capabilities, download a provisioning
profile for the explicit App ID. A signed bundle can then be produced entirely from
the command line:

```sh
security find-identity -v -p codesigning
AERO_SIGNING_IDENTITY='Developer ID Application: …' \
  AERO_PROVISIONING_PROFILE=/path/to/Aero.provisionprofile ./x signed-app
```

`./x signed-app` embeds the profile, enables the entitlements in `Aero.entitlements`,
uses the hardened runtime, and verifies the resulting signature. Normal `./x app`
builds remain ad hoc and do not claim capabilities that Apple has not granted.

After the maintainer explicitly authorizes a release:

1. Choose the version and update `CFBundleShortVersionString` and `CFBundleVersion` in
   `Info.plist`.
2. Run `./x check` and `./x app` on the release commit, on a Mac with Xcode so the icon
   compiles with all its looks. Open the app and try it.
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
