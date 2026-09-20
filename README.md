<p align="center">
  <a href="https://aerobrowser.app">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/Logo/Dark.svg">
    <img src="Assets/Logo/Light.svg" alt="Aero logo" height="42">
  </picture>
  </a>
</p>

Aero is a small, fast macOS browser. It is a native AppKit shell around the system's
WebKit, with no package dependencies. The executable is under 1 MB.

- The whole interface is one strip with the traffic lights, pinned tabs and tabs.
- There is no address bar. A new tab is a single centered field that completes from your
  history, and Command-L brings the same field up over a page.
- The strip takes the color of the page's header, hero or sidebar, so it reads as part of the page.
- The active tab doubles as the loading bar.
- Tabs and address suggestions show each site's icon; Settings can turn that off.
- Pinned tabs show as their site's icon or a monogram, can't be closed, and come back on the next launch.
- Tabs you haven't looked at for half an hour give their memory back and reload where you left
  them when you return.
- Downloads go to the Downloads folder and appear at the right edge of the strip.
- The built-in extensions catalog installs signed app extensions such as 1Password, and local
  WebExtensions can be installed from an unpacked directory or ZIP.
- Website sign-ins share one persistent browsing session. Aero has no browser profiles.
- Reload keeps your place. The page stays still and the strip keeps its color while the new
  copy loads, then the two are lined up before you see it.

## Build

Aero needs macOS 15.4 or newer and a Swift 6 toolchain. The Command Line Tools are enough;
Xcode is not required. The website under `Website/` needs Node.js 22 or newer.

```sh
./x run      # build build/Aero.app and open it
./x check    # check the native app and website
```

The product name lives in one place, `NAME` in `x`.

The app icon is `Assets/app.icon`, an Icon Composer document. With Xcode installed the build
compiles it with `actool`, and macOS renders its Default, Dark, Clear and Tinted looks.
Without Xcode it falls back to a plain `.icns` of the Default look, rendered by Icon
Composer.

## Keys

| | |
|---|---|
| ⌘T / ⌘W | new tab / close tab |
| ⌘L | edit the address |
| ⌘F | find text on the page |
| ⌘P | print the page |
| ⌘D | pin or unpin the current tab, also in the tab's context menu |
| ⌘[ / ⌘] | back / forward, also the arrows in the strip, or swipe |
| ⌘⇧[ / ⌘⇧] | previous / next tab |
| ⌘1–⌘9 | jump to tab |
| ⌘-click | open link in a background tab |

In the address field, ↑ and ↓ pick a suggestion, Tab accepts the completion, Delete
removes it, and Esc dismisses.

## What to expect

Aero renders pages with the same engine as Safari. A page that is slow in Safari is slow
in Aero. Website cookies and sessions persist in WebKit's default data store.
WebExtensions use WebKit's extension runtime, so extensions that depend on browser-specific
APIs may not work. History stays in
`~/Library/Application Support/<bundle id>/history.sqlite` and nothing leaves your Mac.

## Contributing

[AGENTS.md](AGENTS.md) has the code map and the rules the app keeps, and
[CONTRIBUTING.md](CONTRIBUTING.md) covers checks, review and releases. Report
security-sensitive findings through [SECURITY.md](SECURITY.md).

Aero is released under the [MIT license](LICENSE).
