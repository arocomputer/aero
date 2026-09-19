# Security policy

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/fschrhunt/aro/security/advisories/new).
Do not open a public issue containing an exploit or private information.

Include the affected version or commit, the macOS version, a minimal reproduction, and
the expected impact. Use a public or synthetic page for the reproduction and remove
private addresses, history, and page content from attachments.

The maintainer will coordinate reproduction, a fix, and disclosure through the private
report. Do not assume a response deadline or a bounty program.

## Supported versions

Aro has not made its first release. Report findings against current main or an open PR.

## Security boundaries

Aro does not render pages. The system's WebKit loads, runs, and draws them in its own
sandboxed processes, and WebKit's fixes arrive with macOS updates. A flaw in page
rendering, JavaScript, TLS, or the WebKit sandbox belongs to
[Apple](https://support.apple.com/102549), not here.

Aro's own code decides what to load and what to keep:

- It turns typed text into an address or a web search. It loads `http`, `https`,
  `file` and `about` addresses; anything else becomes a search.
- When a person clicks a link with another scheme, such as `mailto:`, Aro hands it to
  macOS. It does not do that for navigations a page starts by itself.
- It injects one script into each page's main frame. The script reads computed styles
  at the top edge of the page and sends back a color or a short tag. It sends nothing
  else, and the native side treats the message as untrusted text.
- It stores visited addresses and titles in a local SQLite file under
  `~/Library/Application Support/`, readable by the user's account. Search result pages
  are not stored. Nothing is uploaded, and Aro has no telemetry.
- It registers as a handler for `http` and `https`, so other apps can ask it to open
  addresses.
- It allows plain `http` pages to load, as browsers do.

The app is not sandboxed and its builds are signed ad hoc. It has no package
dependencies.

## Findings worth reporting

Report typed or opened text that loads something other than what it shows, a page
starting another app without a click, a page reading history or making the native side
act through the injected script's message channel, history written outside the user's
library or containing search result pages, and an address shown in the strip or field
that differs from the page loaded.

A page behaving badly inside its own tab, in a way Safari shares, is not by itself an
Aro vulnerability. An implementation that violates the boundaries above is still a
valid report.

## Automation review

Dependabot proposes weekly updates for GitHub Actions. Actions use full commit pins and
minimal workflow permissions. Pull-request checks must not receive release credentials
or run contributor code with a privileged token. Review changes to address handling,
navigation policy, the injected script, the manifest, and workflows as changes to the
security boundary.
