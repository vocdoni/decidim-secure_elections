/**
 * Builds the `vocdoni` voting backend adapter for Decidim's client-side booth
 * into `public/vocdoni/booth-adapter.js`, a same-origin IIFE bundle with the
 * `@vocdoni/*` packages compiled in.
 *
 *   node build/booth_adapter.mjs
 */
import { fileURLToPath } from "node:url";
import path from "node:path";
import esbuild from "esbuild";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

await esbuild.build({
  entryPoints: [path.join(root, "app/packs/src/decidim/elections/vocdoni/voter/booth_adapter.js")],
  outfile: path.join(root, "public/vocdoni/booth-adapter.js"),
  bundle: true,
  minify: true,
  format: "iife",
  platform: "browser",
  target: ["chrome80", "firefox78", "safari14.1", "edge88"],
  nodePaths: [path.join(root, "app/packs")],
  legalComments: "none",
  tsconfigRaw: {},
  logLevel: "warning"
});

process.stdout.write("booth adapter built into public/vocdoni/booth-adapter.js\n");
