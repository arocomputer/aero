# Working on Aero

Instructions for agents and contributors editing this repository. Read
[CONTRIBUTING.md](CONTRIBUTING.md) for contribution and AI/LLM rules.

Aero is a small, fast macOS browser. It is a native AppKit shell around the system's
WebKit, with no Swift package dependencies. Its interface is one strip holding the traffic
lights, pinned tabs and tabs. There is no address bar; a centered field appears on a new
tab and on Command-L. The repository is `arocomputer/aero`. The Swift module is
`Browser`, so a product rename never touches the sources.

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

## Build and check

```sh
./x hooks      # once per contributing checkout or worktree
./x dev        # the debug build: fast, its own data, in the background and out of the Dock
./x run        # build and start Aero as it ships
./x check      # check the native app, and the website when its packages are installed
```

Aero needs macOS 15.4 or newer and a Swift 6 toolchain. The Command Line Tools are enough;
Xcode is not required. Python 3 runs repository tooling. The website needs Node.js 22 or
newer and `npm ci` from `Website/`. CI runs the same checks.

`./x quality` runs `./x lint` and `./x guard`. `./x lint` checks formatting with
`swift format` in strict mode and builds with warnings as errors. `./x fmt` formats in
place. `./x test` runs the unit tests. `./x run` builds the release bundle and starts it;
`./x app` is that build without the launch, which is what CI and a release call. `./x check`
runs quality, the tests and `./x app`, and the website checks where its packages are installed.

The workflows run on `macos-latest`, so a new Xcode arrives on GitHub's schedule and brings a
new `swift format` with it. Both have a weekly run to meet that on a Monday rather than inside
a pull request. When `./x lint` passes here and fails there, a newer local Xcode is the first
thing to check.

Required checks are `Validate` from Quality and `Build and Test` from App. `Website
Check` runs when `Website/`, its workflow, or `x` changes. Keep those names aligned
with repository rules.

The icon is `Assets/app.icon`, an Icon Composer document. That format is a
folder holding `icon.json` and its artwork; Finder shows it as one file. With Xcode installed, `Scripts/icon.sh`
compiles it with `actool` into `Assets.car`, and macOS renders the Default, Dark, Clear and Tinted looks.
Without Xcode it renders a plain `.icns` of the Default look with Icon Composer's `ictool`.
The `actool` path is covered by `./x app` on a Mac with Xcode installed.

## The development loop

`./x dev` is the one to develop in. It builds unoptimized in seconds, into its own bundle
identifier so it cannot touch the data you browse with, and opens in the background. The Web
Inspector is on, which a release build compiles out.

It is marked `LSUIElement`, so it stays out of the Dock. The menu bar goes with it, macOS
offering no way to drop one and keep the other; the shortcuts still work, but menus, the Dock
icon, ⌘-Tab and full screen are `./x run` territory.

`AERO_LOG=tint,sleep ./x dev` turns on a commentary from the parts that decide something
invisible, followed with `./x log`. The channels are in `Sources/App/Log.swift`.

`./x shot <url> <file.png>` pictures a real window without putting one on screen. It lives in
`Tests/Window/Shot.swift` rather than the app, so the shipping browser cannot be asked to render
a page to a file.

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
  Page/                         a tab and its page: top-edge color, hovered link, site icons, reload hold
  Settings/                     preferences and the settings page
  Downloads/                    WebKit downloads, destinations and current-session state
  Extensions/                   catalog, installed WebExtensions, permissions, actions and popups
Tests/                          focused unit tests, grouped like the source tree; also the
                                offscreen page harness, the tint survey and ./x shot
Assets/                         the app icon's Icon Composer source, logo and wordmark
Website/                       aerobrowser.app source, checks, and deployment
Scripts/                        guard, commit hooks and their tests, icon packaging
```

## Fast test loops

```sh
./x test --filter PageTint
./x test --filter TabSleep
./x test --filter AddressInput
AERO_TEST_TIMEOUT=3 ./x test        # while a script test is failing, stop waiting 20s for it
python3 -m unittest discover -s Scripts/hooks -p 'test_*.py'
```

Tests should pin observable behavior. A regression test must fail against the unfixed
code for the intended reason; check that once by breaking the code on purpose. Tests
cover the types that hold rules. Views have no tests; show a visual change instead, with
`./x shot` and the address it was taken at.

Tests that need a page use `ScriptedPage`, which runs it in a window that is never shown; a new
script test should use it rather than grow another harness. `./x survey` measures the tint script
against real sites, which takes minutes and the network, so it is not part of `./x check`.

Do not send synthetic keyboard or pointer input to a desktop someone is using, and do
not raise test windows over their work without asking. Nothing here needs to.

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

Prefer short names such as `Tab`, `History` and `PageTint`. Let the file and type give
context instead of suffixes such as Manager or Provider. Keep conventional Swift naming
and the standard SwiftPM layout under `Sources/` and `Tests/`.

The README introduces the app, its keys and its layout. Repository policy stays in root
markdown files. Do not create a docs folder or duplicate guides.

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
