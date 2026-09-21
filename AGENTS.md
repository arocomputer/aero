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
place. `./x test` runs the unit tests. `./x run` builds the release bundle — `Info.plist`
filled, the icon compiled, signed ad hoc — and starts it; `./x app` is that same build without
the launch, which is what CI and a release call.
`./x check` runs quality, the tests and `./x app`, so that a bundle which stopped assembling is
caught before CI catches it; it adds `./x website check` only where `Website/node_modules`
exists, which is how CI splits them.

The workflows run on `macos-latest`, which rolls forward on GitHub's schedule and brings a new
Xcode with it. `./x lint` gates on `swift format --strict`, whose version arrives that way, so a
roll can reformat nothing and fail everything on a commit nobody wrote; the same roll is what
keeps the toolchain current, which is why it is worth having. The weekly run on both workflows
exists to meet that on a Monday rather than inside someone's pull request. A local `swift format`
from a newer Xcode than the runner's can also disagree with CI: when `./x lint` passes here and
fails there, that is the first thing to check.

Required checks are `Validate` from Quality and `Build and Test` from App. `Website
Check` runs when `Website/`, its workflow, or `x` changes. Keep those names aligned
with repository rules.

The icon is `Assets/app.icon`, an Icon Composer document. That format is a
folder holding `icon.json` and its artwork; Finder shows it as one file. With Xcode installed, `Scripts/icon.sh`
compiles it with `actool` into `Assets.car`, and macOS renders the Default, Dark, Clear and Tinted looks.
Without Xcode it renders a plain `.icns` of the Default look with Icon Composer's `ictool`.
The `actool` path is covered by `./x app` on a Mac with Xcode installed.

## The development loop

These are the tools, not a procedure. `./x dev`, the log channels and `./x shot` exist because
each removes a real cost from working here; reach for whichever earns its keep for the change
in front of you, and ignore the rest. Nothing below is a step anyone owes a reviewer.

`./x dev` is the one worth defaulting to. It builds unoptimized: about 3 seconds against the 14
`./x app` takes on a warm build of this repository, which also compiles the icon and signs the
bundle. It lays out `build/AeroDev.app`, a separate product with its own bundle identifier, so
its history, site icons, pins and settings are never the ones you browse with and nothing it
does can reach them. It opens in the background rather than taking the screen from what you are
doing, and it replaces a copy already running, which plain `open` would merely bring forward.
The Web Inspector is compiled out of a release build and is on here, so Safari's Develop menu
reaches the page and the extension runtime.

The debug bundle is marked `LSUIElement`, so it takes no place in the Dock or the app switcher
among the apps you actually use. macOS offers no way to drop one and keep the other, so its menu
bar goes too. `AppDelegate` reads that key rather than a flag of its own, and the shipping
`Info.plist` never carries it.

Everything a page does is unaffected: scrolling, clicking, typing, zooming, back and forward,
downloads, extensions, the Web Inspector. So are the menu's shortcuts, which are dispatched
through `NSApp.mainMenu` whether or not a menu bar is drawn; ⌘T, ⌘L, ⌘F and ⌘W were each
confirmed claimed under this policy. Four things it cannot show you, each of which `./x run`
can, so that is where to look when the change is about one of them:

- the menu bar itself, and so a menu item's title, order or enabled state
- the Dock icon and its menu, and the click on it that `applicationShouldHandleReopen` answers
  with a new window
- a place in ⌘-Tab; the window is reached by clicking it or through Mission Control
- full screen, where a menu-bar-less app behaves differently enough not to be trusted here

`AERO_LOG=tint,sleep ./x dev` turns on a commentary from the parts that decide something
invisible, and `./x log` follows it. See `Sources/App/Log.swift` for the channels, and for why
none of them may name a page.

`./x shot <url> <file.png>` writes a picture of a real browser window without putting one on
screen: the strip, the page, and whether the one took its color from the other. It is the
cheapest way to see a visual change and the easiest picture to attach to a PR, though a
screenshot taken by hand says the same thing and a recording says more about motion. It lives
in `Tests/Window/Shot.swift`, not in the app, so the shipping browser has no mode that renders
a page to a file on someone else's say-so.

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
cover the types that hold rules. Views have no tests, so a visual change is shown rather than
asserted; `./x shot` is the quickest way to get that picture, and naming the address it was
taken at makes it reproducible.

The tests that need a page run it in a window that is never shown; `ScriptedPage` in
`Tests/Page/ScriptedPage.swift` is the one harness for that, and a new script test should
use it rather than grow another. `./x survey` measures the tint script against real sites
over the network; it takes minutes, is not part of `./x check`, and only fails when a page
painted and the script said nothing at all about it.

Do not send synthetic keyboard or pointer input to a desktop someone is using, and do
not raise test windows over their work without asking. Nothing here needs to: the tests
and `./x shot` never order a window in, and `./x dev` opens behind what is already there.

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
