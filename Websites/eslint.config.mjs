import js from "@eslint/js";
import tseslint from "typescript-eslint";
import astro from "eslint-plugin-astro";
import { defineConfig, globalIgnores } from "eslint/config";

/** Lint the Astro site and its small amount of TypeScript. */
export default defineConfig([
  globalIgnores(["dist/**", ".astro/**", ".wrangler/**"]),
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...astro.configs.recommended,
]);
