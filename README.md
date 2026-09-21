<p align="center">
  <a href="https://aerobrowser.app">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/Logo/Dark.svg">
    <img src="Assets/Logo/Light.svg" alt="Aero logo" height="42">
  </picture>
  </a>
</p>

Aero is a small, fast macOS browser. It is a native AppKit shell around the system's
WebKit. Sparkle provides signed application updates.

- The whole interface is one strip with the traffic lights, pinned tabs and tabs.
- There is no address bar. A new tab is a single centered field that completes from your
  history, and Command-L brings the same field up over a page.
- The strip takes the color of the page's header, hero or sidebar, so it reads as part of the page.
- The active tab doubles as the loading bar.
- Tabs and address suggestions show each site's icon; Settings can turn that off.
- Hovering a link shows where it really leads, in a small card at the bottom of the page.
- Pinned tabs show as their site's icon or a monogram, can't be closed, and come back on the next launch.
- Tabs you haven't looked at for half an hour give their memory back and reload where you left
  them when you return.
- Downloads go to the Downloads folder and appear at the right edge of the strip.
- The built-in extensions catalog installs signed app extensions such as 1Password, and local
  WebExtensions can be installed from an unpacked directory or ZIP.
- Website sign-ins share one persistent browsing session. Aero has no browser profiles.
- Known third-party trackers are blocked by default using a bundled list compiled by WebKit.
- Hover over a tab to reveal site information. It shows the domain and connection status, with controls
  for tracker blocking, camera and microphone access, and clearing the site's stored data.
- Reload keeps your place. The page stays still and the strip keeps its color while the new
  copy loads, then the two are lined up before you see it.

## Build

Aero needs macOS 15.4 or newer and a Swift 6 toolchain. The Command Line Tools are enough;
Xcode is not required. The website under `Website/` needs Node.js 22 or newer.

```sh
./x dev      # the debug build: fast, its own data, out of the Dock
./x run      # build and start Aero as it ships
./x check    # check the native app and, where installed, the website
```

`./x dev` is the loop to develop in: it builds in seconds, keeps its browsing data apart
from the app you use, has the Web Inspector on, and does not take the screen.

The product name lives in one place, `NAME` in `x`.

The app icon is `Assets/app.icon`, an Icon Composer document. With Xcode installed the build
compiles it with `actool`, and macOS renders its Default, Dark, Clear and Tinted looks.
Without Xcode it falls back to a plain `.icns` of the Default look, rendered by Icon
Composer.

## Keys

| | |
|---|---|
| ⌘T / ⌘W | new tab / close tab |
| ⇧⌘N | new private window |
| ⇧⌘T | reopen a closed ordinary tab |
| ⌘L | edit the address |
| ⌘F | find text on the page |
| ⌘P | print the page |
| ⌘Y | browsing history |
| ⌥⌘L | downloads |
| ⇧⌘⌫ | choose browsing data to delete |
| ⌘D | bookmark the current page |
| ⌥⌘B | bookmark library |
| ⌘[ / ⌘] | back / forward, also the arrows in the strip, or swipe |
| ⌘⇧[ / ⌘⇧] | previous / next tab |
| ⌘1–⌘9 | jump to tab |
| ⌘-click | open link in a background tab |

In the address field, ↑ and ↓ pick a suggestion, Tab accepts the completion, Delete
removes it, and Esc dismisses.

## What to expect

Settings includes startup behavior, custom search engines and shortcuts, nested privacy controls,
website decisions, downloads, accessibility and tab sleeping. Session restoration is opt-in and
periodically saves ordinary window addresses, groups and selection for recovery after a crash.
It never saves private tabs or page forms. History records individual visits; cookie, cache and
website-storage deletion have separate controls.

Website notifications are not supported. WebKit manages website clipboard access. The Passwords
button opens the system app for viewing and copying credentials; it does not enable website autofill.
Password-manager extensions provide a separate route, subject to extension compatibility.

History, bookmarks and downloads have searchable library pages. Bookmarks support HTML import and
export, including folder paths. The browser menu manages named tab groups and collapsing them.
Ordinary downloads continue after their window closes, retain history across launches and support
pause/resume when the server allows it. Existing files are replaced only after a complete download
and explicit replacement approval.

Extensions opens to the installed list. Each extension can be disabled without uninstalling it,
and its details show version, installation source, requested access and grants that can be revoked.
Permission decisions survive restarts. Compatible extensions can supply an opt-in new-tab page.
App Store discovery is separate; its artwork loads only when that section is opened and permitted.
Catalog listings are not compatibility certifications. To troubleshoot a broken extension, quit
the app and run `./x run --disable-extensions`.

Aero renders pages with the same engine as Safari. A page that is slow in Safari is slow
in Aero. Website cookies and sessions persist in WebKit's default data store.
WebExtensions use WebKit's extension runtime, so extensions that depend on browser-specific
APIs may not work. History stays in the app's sandbox container and Aero does not upload it.

Aero asks WebKit to upgrade HTTP navigation to HTTPS and warn before falling back. Certificate
validation, fraudulent-site warnings and system Lockdown Mode remain WebKit's responsibility.
Localhost, mDNS `.local` names and private or link-local IP addresses can still use explicit HTTP.
Website safety checks can use Apple's configured services. Protection-list updates require a
publisher key and signed list; their requests never include visited addresses. Global Privacy
Control uses the native WebKit policy on macOS 27 and later. Google remains the default search
engine. Remote Google suggestions are optional and never requested for addresses or private tabs.

Private windows share an in-memory website store only within that window. They do not save history,
icons, tab recovery or download records and do not load third-party extensions. Closing the window
stops unfinished private downloads and discards its website data; completed files remain. Ephemeral
sign-in tabs use the same recording restrictions.

The native app uses App Sandbox and hardened runtime. On first sandboxed launch, macOS migrates
the current bundle identity's browser data into its container. A previously chosen download folder
outside Downloads may need to be selected again in Settings to authorize access. Location blocking
in Site Information requires macOS 27's WebKit permission delegate; older versions use system controls.
System encrypted DNS uses Apple's DNS-settings API and requires a correctly provisioned build and
activation in macOS. It affects all apps, not only this browser. Updates use Sparkle; signed delivery
requires the publisher's own configured key, feed and release artifacts.

## Contributing

[AGENTS.md](AGENTS.md) has the code map and the rules the app keeps, and
[CONTRIBUTING.md](CONTRIBUTING.md) covers checks, review and releases. Report
security-sensitive findings through [SECURITY.md](SECURITY.md).

Aero is released under the [MIT license](LICENSE).
