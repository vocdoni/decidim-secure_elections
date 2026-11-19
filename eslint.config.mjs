import { defineConfig, globalIgnores } from "eslint/config";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import js from "@eslint/js";
import { FlatCompat } from "@eslint/eslintrc";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const require = createRequire(import.meta.url);
const compat = new FlatCompat({
  baseDirectory: __dirname,
  recommendedConfig: js.configs.recommended,
  allConfig: js.configs.all
});

// Decidim's own rules, vendored rather than extended — see the header of the
// file for why. This repository has to lint from a plain `git clone && npm ci`,
// and `@decidim/eslint-config` for 0.33 is not on npm.
const decidim = require("./config/lint/decidim-eslint.cjs");

export default defineConfig([
  globalIgnores([
    "**/node_modules/**/*",
    "**/*.min.js",
    "**/coverage",
    "public/vocdoni/**/*"
  ]),
  ...compat.config(decidim),
  {
    // ARCHITECTURE §0.4 — the voter path handles the census credential, the
    // ephemeral private key and the cleartext ballot. The previous generation of
    // this module printed all three to the browser console, which turned every
    // shared/recorded screen into a vote-disclosure channel.
    //
    // `no-console` is an error here and there is no `eslint-disable` exemption
    // worth granting: if you need to observe the flow, surface it in the UI
    // through the aria-live status region, which is auditable by design.
    files: ["app/packs/src/decidim/elections/vocdoni/voter/**/*.js"],
    ignores: ["app/packs/src/decidim/elections/vocdoni/voter/**/*.test.js"],
    rules: {
      "no-console": "error",
      "no-alert": "error",
      // The ballot and the auth token must never survive the page: no storage,
      // no URL, no cookie.
      "no-restricted-globals": [
        "error",
        { name: "localStorage", message: "The voter path must not persist anything (ARCHITECTURE §0)." },
        { name: "sessionStorage", message: "The voter path must not persist anything (ARCHITECTURE §0)." }
      ],
      "no-restricted-properties": [
        "error",
        { object: "window", property: "localStorage", message: "The voter path must not persist anything (ARCHITECTURE §0)." },
        { object: "window", property: "sessionStorage", message: "The voter path must not persist anything (ARCHITECTURE §0)." },
        { object: "document", property: "cookie", message: "The voter path must not persist anything (ARCHITECTURE §0)." }
      ]
    }
  },
  {
    // The build script is a Node program, not browser code: it produces the
    // booth adapter bundle, so it is linted too, with Node's globals.
    files: ["build/**/*.mjs"],
    languageOptions: {
      globals: { process: "readonly", console: "readonly" }
    }
  }
]);
