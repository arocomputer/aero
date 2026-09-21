# Page

One tab and the page inside it. Two things here run across Swift and JavaScript, and neither
file owns the whole story, which is why this note exists. Everything else is in the doc comment
at the top of each file; where the two disagree, the comment beside the code is right.

## The strip's color

`PageTint.js` decides, from styles alone, what the page shows along its top edge, and posts a
string whenever it changes: `r,g,b`, `page`, or `unknown:<n>:<look>` when a band is painted by an
image or a gradient. A `~<ms>,<easing>` suffix means the page's own header is fading there. What
counts as the top edge, and what is deliberately ignored, is the long comment in that file.

    PageTint.js  -> TintRouter  -> Tab.pageTint  -> Tab.owner
    reports         routes to      decides         WindowController.tabTintDidChange
                    the tab                        -> Strip.setTint

`PageTint` is where the cost is controlled. A color is shown at once. `unknown` buys at most one
snapshot per look of an element and `maxSnapshots` per page, taken only once the page has loaded
and both scrolling and reports have gone quiet, because a snapshot makes the page paint on its
main thread. `Tab` supplies that snapshot as a 2px-tall strip run through `DominantColor`.

`Strip.setTint` puts the answer on a layer, and runs the page's own fade when one was reported,
so the two change as one.

## The reload that does not move

`ReloadHold` covers the web view with a still picture, reloads underneath, and puts the page back
where it was before uncovering. It carries two scripts: `noteAnchor` picks an element near the
top that can be found again, and `settleAndAlign` waits for the new page to stop moving, lines
the anchor up, and holds it there against late layout shifts.

## Rules that bite here

- Scripts are injected into `.defaultClient`, never the page's own world, so a page can neither
  read them nor forge their reports.
- Whatever runs inside a page or makes it paint is paid for by the person scrolling it. Rare,
  cheap, and measured before it is called cheap.
- A tab nobody is looking at gives its page back; `Tab.sleepBlocker` names every reason one may
  not, and `TabSleepTests` pins them.
