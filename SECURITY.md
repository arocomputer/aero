# Security policy

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/arocomputer/aero/security/advisories/new).
Do not open a public issue containing an exploit or private information.

Include the affected version or commit, the macOS version, a minimal reproduction, and
the expected impact. Use a public or synthetic page for the reproduction and remove
private addresses, history, and page content from attachments.

The maintainer will coordinate reproduction, a fix, and disclosure through the private
report. Do not assume a response deadline or a bounty program.

## Supported versions

Aero has not made its first release. Report findings against current main or an open PR.

## Security boundaries

Aero does not render pages. The system's WebKit loads, runs, and draws them in its own
sandboxed processes, and WebKit's fixes arrive with macOS updates. A flaw in page
rendering, JavaScript, TLS, or the WebKit sandbox belongs to
[Apple](https://support.apple.com/102549), not here.

Aero's own code decides what to load and what to keep:

- It turns typed text into an address or a web search. It loads `http`, `https`,
  `file` and `about` addresses; anything else becomes a search.
- Links that open another app require a top-level click and native confirmation.
  Script redirects and embedded-frame requests cannot launch another app.
- Scripts in WebKit's isolated client world report page tint, hovered links and editing state.
  The native side treats their messages as untrusted input.
- Local settings, extension and library commands require their own top-level initiating origin.
  Embedded local pages cannot invoke those commands. Local pages restrict resources with CSP.
- It stores visited addresses and titles in a local SQLite file under
  its sandbox container, readable by the user's account. Search result pages and ephemeral
  sign-in activity are not stored. Aero does not upload its history and has no telemetry.
  History retention is configurable. Separately, opt-in session restoration periodically saves ordinary
  window addresses, groups and selection for crash recovery, including search pages that remain open.
- Private windows use a nonpersistent WebKit store, exclude third-party extensions and never enter
  saved sessions, history, icon caches or persistent download records. Completed downloaded files and
  explicitly saved bookmarks remain. Private windows end their unfinished transfers when closed.
- Remote Google suggestions are opt-in. They are not requested for private tabs or address-like input.
  Suggestion requests use an ephemeral session without cookies or stored credentials.
- It registers as a handler for `http` and `https`, so other apps can ask it to open
  addresses.
- It requests WebKit's HTTPS-first navigation with a user-mediated fallback warning, and keeps
  certificate validation and fraudulent-website warnings enabled. These are system WebKit
  policies, not a guarantee that every request uses HTTPS or that every harmful site is detected.
- Known third-party trackers are blocked using a locally compiled domain list. Host exceptions are
  explicit and local. Network list updates require the publisher's Ed25519 signature, bounded valid
  input and a nondecreasing list version; failures retain the working list.
- Global Privacy Control uses the public native WebKit preference on macOS 27 and later. It is an
   opt-out signal, not enforcement of a website's data practices. There is no canvas-spoofing script.
- Enhanced web security uses WebKit's exploit hardening on macOS 26.4 and later. System Lockdown
  remains effective regardless of the selected mode. Public WebKit APIs do not expose advanced
  fingerprinting controls or accurate content-blocker request counts to Aero.
- Website notifications are unsupported. WebKit controls clipboard access through its own
  interaction and paste rules; Aero does not offer persistent per-site clipboard grants.
- Per-origin camera and microphone denials take precedence over WebKit approval. Location
  denials use the public delegate available on macOS 27; earlier systems use OS controls.
- Downloads opt into macOS quarantine and are never opened automatically.
  Transfers finish in staging before committing to their destination. Existing files require explicit
  replacement approval and remain intact if the replacement cannot be completed.
- Encrypted DNS configuration uses the system Network Extension API. It requires the managed
  DNS-settings entitlement and user activation in macOS, and affects all apps. The browser does not
  intercept TLS traffic or install a custom certificate authority.

The native app uses App Sandbox and hardened runtime. Local builds are signed ad hoc;
distribution still requires Developer ID signing and notarization. Sparkle verifies signed update
feeds and archives before extraction; update delivery requires the publisher's configured key and feed.
Ad hoc development builds disable library validation to load the embedded framework. Developer ID
builds retain library validation. Sparkle is the sole approved package dependency. The sandbox is not a boundary against other
software running as the same user, and tracker blocking does not provide anonymity.

## Findings worth reporting

Report typed or opened text that loads something other than what it shows, a page
starting another app without a click, a page reading history or making the native side
act through the injected script's message channel, history written outside the user's
library or containing search result pages, and an address shown in the strip or field
that differs from the page loaded.

A page behaving badly inside its own tab, in a way Safari shares, is not by itself an
Aero vulnerability. An implementation that violates the boundaries above is still a
valid report.

## Automation review

Dependabot proposes weekly updates for GitHub Actions. Actions use full commit pins and
minimal workflow permissions. Pull-request checks must not receive release credentials
or run contributor code with a privileged token. Review changes to address handling,
navigation policy, the injected script, the manifest, and workflows as changes to the
security boundary.
