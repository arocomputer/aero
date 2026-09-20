import { defineConfig } from "astro/config";

/** Build the standalone Aero website for its canonical domain. */
export default defineConfig({
  site: "https://aerobrowser.app",
  output: "static",
  trailingSlash: "never",
  build: { format: "file" },
  devToolbar: { enabled: false },
});
