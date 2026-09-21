# Website

[aerobrowser.app](https://aerobrowser.app): a static marketing site that happens to live in the
browser's repository. It shares nothing with the app but the logo and the name, and it has its
own toolchain, its own workflow and its own deploy. Working on it needs none of AGENTS.md except
the working style.

```sh
npm ci                # once
npm run dev           # astro dev
npm run check         # what CI runs: format, lint, typecheck, audit, build, tests
npm run preview       # build, then serve it through wrangler as production will
```

Astro builds `src/pages` to static files in `dist`; there is no server-side code. Cloudflare
serves `dist` as a Worker's assets, on the custom domain in `wrangler.jsonc`. `npm run deploy`
does that, and CI does it on a push to `main`, so it is not something to run by hand.

`tests/site.test.mjs` reads the built output rather than the sources, which is why `npm test`
builds first. It checks the things a broken build still produces silently: the canonical domain,
the 404 page, `security.txt`.

Astro is pinned exactly and so is wrangler; dependabot proposes one grouped update a week. The
site needs Node.js 22 or newer.

## From the repository root

`./x website <script>` runs any of the scripts above. `./x check` includes the website checks
only when `node_modules` is present, so a Swift-only change does not fail on a missing install;
the `Website Check` workflow runs on changes to `Website/`, its workflow, or `x`.
