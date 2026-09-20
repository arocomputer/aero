import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { URL } from "node:url";

/** Read one generated site file as UTF-8. */
function built(path) {
  return readFile(new URL(`../dist/${path}`, import.meta.url), "utf8");
}

test("generated pages use the canonical Aero domain", async () => {
  const [home, missing, security] = await Promise.all([
    built("index.html"),
    built("404.html"),
    built(".well-known/security.txt"),
  ]);

  assert.match(home, /https:\/\/aerobrowser\.app/);
  assert.match(missing, /href="\/"/);
  assert.match(
    security,
    /Canonical: https:\/\/aerobrowser\.app\/\.well-known\/security\.txt/,
  );
  assert.doesNotMatch(`${home}${missing}${security}`, /aero\.aro\.computer/);
});
