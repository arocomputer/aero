# Working on Aero

Instructions for agents and contributors editing this repository. Read
[CONTRIBUTING.md](CONTRIBUTING.md) for contribution and AI/LLM rules.

Aero is a small, fast macOS browser. It is a native AppKit shell around the system's
WebKit, with no package dependencies. Its interface is one strip holding the traffic
lights, pinned tabs and tabs. There is no address bar; a centered field appears on a new
tab and on Command-L. The repository is `arocomputer/aero`. The Swift module is
`Browser`, so a product rename never touches the sources.

## Working style

- Preserve unrelated changes. Never revert or reformat files outside the task.
- Never expose secrets. History, addresses and page content are private; keep them out
  of fixtures, screenshots and logs.
- In a managed `~/Code` collection, follow its README and work in a managed worktree.
  Base checkouts under `repos/` are for updates, not coding. Other contributors can
  use an ordinary checkout.
- Choose the smallest concrete design that solves the problem. A new abstraction,
  dependency, setting, or menu item needs a use case beyond symmetry.
- Document types and nontrivial functions by purpose. Update comments and guides when
  behavior changes; do not append corrections to stale guidance.
- Claim performance only with reproducible evidence. Say what you measured, how, and
  what you could not measure.

## Build and check

```sh
./x hooks      # once per contributing checkout or worktree
./x check      # format lint, warnings as errors, guard, hook tests, unit tests
./x run        # build build/Aero.app and open it
```

Aero needs macOS 15.4 or newer and a Swift 6 toolchain. The Command Line Tools are enough;
Xcode is not required. Python 3 runs repository tooling. CI runs the same `./x` commands
on macOS.

`./x quality` runs `./x lint` and `./x guard`. `./x lint` checks formatting with
`swift format` in strict mode and builds with warnings as errors. `./x fmt` formats in
place. `./x test` runs the unit tests. `./x app` builds the release bundle, fills
`Info.plist`, adds the icon and signs it ad hoc.

Required checks are `Validate` from Quality and `Build and Test` from App. Keep those
names aligned with repository rules.

The icon is `Sources/UI/aero.icon`, an Icon Composer document. That format is a
folder holding `icon.json` and its artwork; Finder shows it as one file. With Xcode installed, `scripts/icon.sh`
compiles it with `actool` into `Assets.car`, and macOS renders the Default, Dark, Clear and Tinted looks.
Without Xcode it renders a plain `.icns` of the Default look with Icon Composer's `ictool`.
The `actool` path is covered by `./x app` on a Mac with Xcode installed.

## Where things live

```text
Package.swift                   one executable target, Browser, and its tests
Info.plist                      bundle template; ./x app fills __NAME__ and __BUNDLE_ID__
x                               contributor and CI commands; also holds the product name
Sources/Core/                   entry point, menus, app paths, addresses and history
Sources/Downloads/              WebKit downloads, destinations and current-session state
Sources/Extensions/             catalog, installed WebExtensions, permissions, actions and popups
Sources/UI/                     windows, tab strip, address field and app icon
  aero.icon/                    Icon Composer source for the app icon; excluded from the target
Sources/Web/                    web views, page-edge color sampling, pins and reload hold
Sources/Website/                the website; excluded from the Swift target
Tests/                          focused unit tests, grouped like the source tree
scripts/                        guard, commit hooks and their tests, icon packaging
```

## Fast test loops

```sh
./x test --filter PageEdge
./x test --filter History
./x test --filter AddressInput
python3 -m unittest discover -s scripts/hooks -p 'test_*.py'
```

Tests should pin observable behavior. A regression test must fail against the unfixed
code for the intended reason; check that once by breaking the code on purpose. Tests
cover the types that hold rules. Views have no tests. Verify a visual change by running
the app and capturing its window, and say so in the PR.

Do not send synthetic keyboard or pointer input to a desktop someone is using, and do
not raise test windows over their work without asking.

## App boundaries

- The engine is the system's WebKit. How fast a page renders and scrolls is WebKit's
  doing. Before blaming Aero for a slow page, compare Safari and a bare `WKWebView` in a
  plain window on the same Mac. If those are slow too, no change here will fix it.
- Aero runs one script inside pages, the top-edge probe in `Sources/Web/PageEdge.swift`. Anything that
  runs inside a page or makes it paint costs the page. The probe runs on load, resize and
  scroll, at most ten times a second, and never listens to animations. A pixel snapshot
  freezes the page while it paints, up to half a second on a page full of canvases, so
  each painted element gets one per page, after loading, while nothing scrolls. Change
  these limits only with measurements.
- Aero has no package dependencies, and `scripts/guard.py` enforces it. It uses no private
  WebKit API today. Adding either needs a stated reason, evidence that it helps, and for
  private API a run-time lookup that does nothing when the method is gone.
- The strip has no surface of its own. It takes its color from what touches the page's
  top edge, but only from two kinds of element. A pinned one, fixed or sticky, such as a
  sticky header or an app's sidebar, comes first. A band spanning nearly the full width,
  such as a hero, comes second. Cards and columns scrolling past never count, or the
  strip would flicker on every feed; without either kind it shows the page's background.
  It switches its appearance to light or dark to stay legible. It never uses a page's
  declared theme color, which sites often set to a brand color that matches nothing
  under the strip.
- Reload goes through `ReloadHold`. Sites restore their own scroll position after a
  reload and shift their layout for a second afterwards, so a plain reload shows the top,
  jumps back and nudges the text, in every browser. The hold covers the page with a still
  picture, waits for the new page to settle, lines it up with an anchor element noted
  beforehand, uncovers, and keeps the anchor in place for 2.5s more. The strip keeps the
  color it had when the picture was taken for as long as the hold lasts. Its one snapshot
  is taken before the reload, when a pause costs nothing. Measure before changing its
  timings: log an element's viewport position through a reload, with and without it.
- The window is a system toolbar window. Its corners and titlebar height are the
  system's. The traffic lights are the system's buttons drawn larger; do not replace
  them with custom drawing.
- Motion marks things that appear, leave or move, stays under 200ms and can be
  interrupted. Typed text is never animated.
- History is one local SQLite table, written on the main thread with a write-ahead log.
  Nothing leaves the Mac. Search result pages are not recorded.
- Website accounts use one persistent WebKit data store. Aero has no browser profiles or
  separate identity layer.
- The product name lives in `x` and the bundle. Do not hardcode it in sources.

## Naming and documentation

Prefer short names such as `Tab`, `History` and `PageEdge`. Let the file and type give
context instead of suffixes such as Manager or Provider. Keep conventional Swift naming
and the standard SwiftPM layout under `Sources/` and `Tests/`.

The README introduces the app, its keys and its layout. Repository policy stays in root
markdown files. Do not create a docs folder or duplicate guides.

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

`scripts/guard.py` checks action pins and that `Package.swift` declares no dependencies.
A legitimate boundary change updates the guard with an explanation; do not bypass it.
There is no release automation yet. See CONTRIBUTING.md before preparing a release.
