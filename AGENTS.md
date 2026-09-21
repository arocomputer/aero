# Working on Aero

Instructions for agents and contributors editing this repository. The README introduces the
app; [CONTRIBUTING.md](CONTRIBUTING.md) covers contribution and AI/LLM rules.

- The repository is `arocomputer/aero` and `main` is its default branch.
- The Swift module is `Browser`, so a product rename never touches the sources.
- Aero needs macOS 15.4 or newer and a Swift 6 toolchain. The Command Line Tools are enough;
  Xcode is not required. Python 3 runs the repository tooling, and `Website/` needs Node.js 22
  or newer and `npm ci`.

## Working style

- Preserve unrelated changes. Never revert or reformat files outside the task.
- Never expose secrets. History, addresses and page content are private; keep them out
  of fixtures, screenshots and logs.
- Choose the smallest concrete design that solves the problem. A new abstraction,
  dependency, setting, or menu item needs a use case beyond symmetry.
- Document types and nontrivial functions by purpose. Update comments and guides when
  behavior changes; do not append corrections to stale guidance.
- Claim performance only with reproducible evidence. Say what you measured, how, and
  what you could not measure.

## Commands

| | |
| --- | --- |
| `./x hooks` | once per checkout or worktree |
| `./x dev [url]` | the loop to develop in; see below |
| `./x run` | build and start Aero as it ships |
| `./x test --filter <name>` | one group of tests |
| `./x shot <url> <file.png>` | picture a real window without putting one on screen |
| `./x log` | follow what `AERO_LOG` turned on |
| `./x check` | what CI runs |

`./x` with no argument lists the rest: `app`, `quality`, `lint`, `fmt`, `guard`, `survey`,
`website`, `clean`. Those are pieces the four above call, or things you need once a year.

## What to run

Narrowest first. Each step costs more than the one above it, so earn it.

1. `./x test --filter <name>` while working. `AERO_TEST_TIMEOUT=3` stops a failing script test
   waiting out its 20 s settle.
2. `./x test` before believing it works.
3. `./x check` before a pull request: quality, the tests, and `./x app`, so a bundle that
   stopped assembling is caught here rather than in CI. It adds the website checks only where
   `Website/node_modules` exists, which is how CI splits them.
4. `./x run` when the change is about the menu bar, the Dock icon, ⌘-Tab or full screen. `./x dev`
   cannot show those.

Required checks are `Validate` from Quality and `Build and Test` from App. `Website Check` runs
when `Website/`, its workflow, or `x` changes. Keep those names aligned with repository rules.

Workflows run on `macos-latest`, so a new Xcode — and with it a new `swift format` — arrives on
GitHub's schedule. Both have a weekly run to meet that on a Monday rather than inside a pull
request. When `./x lint` passes here and fails there, a newer local Xcode is the first thing to
check.

The icon is `Assets/app.icon`, an Icon Composer document: a folder holding `icon.json` and its
artwork, which Finder shows as one file. With Xcode, `Scripts/icon.sh` compiles it with `actool`
into `Assets.car` and macOS renders the Default, Dark, Clear and Tinted looks; without Xcode it
falls back to a plain `.icns` of the Default look. `./x app` covers the `actool` path.

## The development loop

- `./x dev` builds unoptimized in seconds, under its own bundle identifier so it cannot touch the
  data you browse with, and opens in the background. The Web Inspector is on, which a release
  build compiles out.
- It is marked `LSUIElement`, so it stays out of the Dock. macOS drops the menu bar with that and
  offers no way to keep one without the other; the shortcuts still work, but menus, the Dock icon,
  ⌘-Tab and full screen need `./x run`.
- `AERO_LOG=tint,sleep ./x dev` turns on a commentary from the parts that decide something
  invisible; `./x log` follows it. The channels are in `Sources/App/Log.swift`.
- `./x shot` lives in `Tests/Window/Shot.swift` rather than the app, so the shipping browser
  cannot be asked to render a page to a file.

## Where things live

```text
Package.swift                   one executable target, Browser, and its tests
Info.plist                      bundle template; ./x app fills __NAME__ and __BUNDLE_ID__
x                               contributor and CI commands; also holds the product name
Sources/                        the app, one folder per feature
  App/                          entry point, main menu, app paths, passkeys, the log channels
  Window/                       the browser window and its controller, the browser menu, find, the link bubble
  Strip/                        the tab strip and its items
  Omnibox/                      the address field, address parsing, history
  Page/                         a tab and its page: top-edge color, hovered link, site icons,
                                reload hold; its README maps the two Swift-and-JavaScript pipelines
  Settings/                     preferences and the settings page
  Downloads/                    WebKit downloads, destinations and current-session state
  Extensions/                   catalog, installed WebExtensions, permissions, actions and popups
Tests/                          focused unit tests, grouped like the source tree; also the
                                offscreen page harness, the tint survey and ./x shot
Assets/                         the app icon's Icon Composer source, logo and wordmark
Website/                        aerobrowser.app: its own toolchain and deploy, and a README
Scripts/                        guard, commit hooks and their tests, icon packaging
```

## Tests

- Pin observable behavior. A regression test must fail against the unfixed code for the intended
  reason; check that once by breaking the code on purpose, and never weaken an assertion to make
  one pass.
- Test the types that hold rules. Views have no tests; show a visual change instead, with
  `./x shot` and the address it was taken at.
- A test that needs a page uses `ScriptedPage`, which runs it in a window that is never shown.
  Use it rather than growing a second harness.
- `./x survey` measures the tint script against real sites. It needs minutes and the network, so
  it is not part of `./x check`.
- The hook tests are Python: `python3 -m unittest discover -s Scripts/hooks -p 'test_*.py'`.

Do not send synthetic keyboard or pointer input to a desktop someone is using, and do not raise
test windows over their work without asking. Nothing here needs to.

## What Aero is

These say what Aero is for. They are intent, not mechanism: how each one is met lives in the doc
comments beside the code, which is also where the numbers, timings and trade-offs are kept. A
better way to meet one of them is welcome; change the code and its comments, not this list.

- The strip is one with the page. It has no surface of its own: it takes the color the page shows
  along its top, and changes the way the page changes, fading when the header fades, so that window
  and page read as one object. It stays legible by switching its own appearance to light or dark.
  It follows what stays put, a header, a sidebar, a hero, never the cards and columns scrolling
  past, and never a page's declared theme color.
- The chrome must not cost the page. Whatever runs inside a page or makes it paint is paid for by
  the person scrolling it, so it is rare, cheap and out of the page's reach. Claim a cost or a
  saving only with a measurement, and say how it was taken.
- The engine is the system's WebKit. How fast a page renders is WebKit's doing: before blaming
  Aero for a slow page, compare Safari and a bare `WKWebView` on the same Mac.
- Memory is given back. A tab nobody is looking at should not hold what a page costs, and giving
  it up must not lose anything the person would miss.
- Nothing leaves the Mac. History and site icons are local files, search result pages are not
  recorded, and clearing history clears everything that names a visited site. Website accounts
  use one persistent WebKit data store; there are no profiles.
- The window is the system's: a toolbar window with the system's corners, titlebar height and
  traffic lights, drawn larger but never replaced.
- Motion marks things that appear, leave or move, is brief and can be interrupted. Typed text is
  never animated, and neither is the address field: it and its suggestions appear and change at
  once. A reload should look as if nothing moved.
- Aero has no Swift package dependencies, and `Scripts/guard.py` enforces it.
- The product name lives in `x` and the bundle. Do not hardcode it in sources.

## Naming and documentation

Short names. Let the file and the type give the context a suffix would.

```swift
// Good
final class Tab {}
enum PageTint {}

// Bad
final class TabManager {}
enum PageTintProvider {}
```

Keep conventional Swift naming and the standard SwiftPM layout under `Sources/` and `Tests/`.

The README introduces the app, its keys and its layout. Repository policy stays in root
markdown files. Do not create a docs folder.

A folder earns a README when several files work together and no single file owns that story.
`Sources/Page/README.md` maps the tint and reload pipelines across Swift and JavaScript;
`Website/README.md` covers a project with its own toolchain and deploy. Neither restates a doc
comment or this file, and where they disagree the comment beside the code is right. Every other
folder is small enough that its files speak for themselves; leave them alone. A README under
`Sources/` must also be listed in `Package.swift`'s `exclude`, or the build fails on it.

This file states intent and how to work here. Mechanisms, numbers and the reasons behind them
live in doc comments beside the code they describe, where a change to one changes the other.
When guidance becomes wrong, rewrite it rather than appending another account. Git history
keeps past decisions.

## Branches and review

- `main` is the default branch. Before pushing, use `<type>/<slug>`, such as
  `fix/strip-highlight` or `chore/repository-guides`. Do not push main unless explicitly
  authorized. Never force-push another contributor's work.
- Open a PR only when asked. Keep its scope coherent and its description about the final
  change. Do not merge or create releases without an explicit maintainer instruction.
- Use conventional commit titles. Scopes, when useful, are `strip`, `omnibox`, `tab`,
  `page`, `history`, `infra` and `docs`.
- Use `.github/pull_request_template.md`. Explain the problem, what changed, why it
  works, and the checks run with their results. Link an issue when applicable. Include
  screenshots or recordings for visual changes and measurements for performance claims.
- Do not apply PR labels or add automatic PR labeling. Describe the change type in the
  title and template. Issue labels are separate.
- GitHub Releases are the changelog; use the release-note format in CONTRIBUTING.md. Do
  not add a changelog file or a roadmap.
- Follow the AI/LLM rules in CONTRIBUTING.md. Do not add AI attribution trailers or
  model/harness footers to commits or PRs.

## Repository automation

`./x` defines the contributor commands. Keep checks there and have CI call them. Actions
are pinned to full commit SHAs and workflows use minimal permissions. Never execute
contributor code with a privileged PR token.

`Scripts/guard.py` checks action pins and that `Package.swift` declares no dependencies.
A legitimate boundary change updates the guard with an explanation; do not bypass it.
The website deploys separately from app releases.
See CONTRIBUTING.md before preparing a release.
