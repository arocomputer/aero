# Aero

Aero is a small, fast macOS browser. It is a native AppKit shell around the system's
WebKit, with no package dependencies. The app is about 1 MB.

- The whole interface is one strip with the traffic lights, pinned tabs and tabs.
- There is no address bar. A new tab is a single centered field that completes from your
  history, and Command-L brings the same field up over a page.
- The strip takes the color of the page's header, hero or sidebar, so it reads as part of the page.
- The active tab doubles as the loading bar.
- Pinned tabs show as monograms, can't be closed, and come back on the next launch.
- Reload keeps your place. The page stays still and the strip keeps its color while the new
  copy loads, then the two are lined up before you see it.

Aero is early in development.

## Build

Aero needs macOS 14 or newer and a Swift 6 toolchain. The Command Line Tools are enough;
Xcode is not required.

```sh
./x run      # build build/Aero.app and open it
./x check    # format lint, warnings as errors, guard, hook tests, unit tests
```

The product name lives in one place, `NAME` in `x`.

The app icon is `Sources/Browser/AppIcon.icon`, an Icon Composer document. With Xcode installed the build
compiles it with `actool`, and macOS renders its Default, Dark, Clear and Tinted looks.
Without Xcode it falls back to a plain `.icns` of the Default look, rendered by Icon
Composer.

## Keys

| | |
|---|---|
| ⌘T / ⌘W | new tab / close tab |
| ⌘L | edit the address |
| ⌘D | pin or unpin the current tab, also in the tab's context menu |
| ⌘[ / ⌘] | back / forward, or swipe |
| ⌘⇧[ / ⌘⇧] | previous / next tab |
| ⌘1–⌘9 | jump to tab |
| ⌘-click | open link in a background tab |

In the address field, ↑ and ↓ pick a suggestion, Tab accepts the completion, Delete
removes it, and Esc dismisses.

## What to expect

Aero renders pages with the same engine as Safari. A page that is slow in Safari is slow
in Aero, and Chrome extensions do not work. History stays in
`~/Library/Application Support/<bundle id>/history.sqlite` and nothing leaves your Mac.

## Contributing

[AGENTS.md](AGENTS.md) has the code map and the rules the app keeps, and
[CONTRIBUTING.md](CONTRIBUTING.md) covers checks, review and releases. Report
security-sensitive findings through [SECURITY.md](SECURITY.md).

Aero is released under the [MIT license](LICENSE).
