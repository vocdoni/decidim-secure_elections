/**
 * Builds the self-contained voting page into `public/vocdoni/`.
 *
 *   npm run build:vote
 *
 * The voting page is a static page shipped inside the gem: it must work with
 * nothing from Rails at request time, and it must be there the moment the gem is
 * installed. That means the output of this script is **committed**, and
 * `s.files` in the gemspec ships it. Re-run this script and commit the result
 * whenever anything under `app/packs/src/decidim/elections/vocdoni/voter/` or the
 * `votes.page` strings in `config/locales/` change.
 *
 * What it produces:
 *
 *   public/vocdoni/vote.html           the shell, copied verbatim
 *   public/vocdoni/vote.css            minified
 *   public/vocdoni/vote.js             one IIFE bundle, dependencies included
 *   public/vocdoni/booth.html          the legacy redirect, copied verbatim
 *   public/vocdoni/fonts/*.woff2       Source Sans Pro, copied verbatim
 *   public/vocdoni/locales/<tag>.json  the voting page strings, per locale
 *   public/vocdoni/locales/index.json  which locales exist
 *
 * The bundle is fully self-contained on purpose. The `@vocdoni/*` packages and
 * the `@noble/curves` override are compiled *in*, because the page cannot reach
 * the host application's `node_modules` and is not part of its Shakapacker
 * manifest.
 */

import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";
import path from "node:path";
import esbuild from "esbuild";
import yaml from "js-yaml";

const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = path.join(root, "app/packs/src/decidim/elections/vocdoni/voter");
const fontSource = path.join(root, "app/packs/fonts/decidim/elections/vocdoni");
const output = path.join(root, "public/vocdoni");
const localesOut = path.join(output, "locales");
const fontsOut = path.join(output, "fonts");

/** The one locale the voting page is guaranteed to be able to fall back to. */
const DEFAULT_LOCALE = "en";

/**
 * Reads a nested key path out of a translation tree.
 *
 * @param {Object} tree - the translation tree.
 * @param {string} keyPath - a dotted key path.
 * @returns {*} the value, or undefined.
 */
const dig = (tree, keyPath) => keyPath.split(".").
  reduce((node, key) => (node && typeof node === "object"
    ? node[key]
    : undefined), tree);

/**
 * Merges `source` over `target`, recursing into plain objects.
 *
 * @param {Object} target - the base tree.
 * @param {Object} extra - the tree to merge in.
 * @returns {Object} the merged tree.
 */
const deepMerge = (target, extra) => {
  const merged = { ...target };

  Object.entries(extra || {}).forEach(([key, value]) => {
    merged[key] = value && typeof value === "object" && !Array.isArray(value)
      ? deepMerge(merged[key] || {}, value)
      : value;
  });

  return merged;
};

/**
 * Every locale tree the gem ships, merged across the `config/locales/*.yml`
 * files that contribute to it. The locale is the file's top-level key, not its
 * name: `en.vote.yml` and `en.yml` are both `en`.
 *
 * @returns {Promise<Object>} `{ en: {...}, ca: {...} }`.
 */
const readLocaleTrees = async () => {
  const dir = path.join(root, "config/locales");
  const files = (await fs.readdir(dir)).filter((name) => name.endsWith(".yml")).sort();
  const trees = {};

  for (const name of files) {
    const parsed = yaml.load(await fs.readFile(path.join(dir, name), "utf8")) || {};

    Object.entries(parsed).forEach(([locale, tree]) => {
      trees[locale] = deepMerge(trees[locale] || {}, tree);
    });
  }

  return trees;
};

/**
 * The strings the voting page needs, pulled out of one locale tree.
 *
 * The `votes.page` subtree is taken wholesale — its shape *is* the voting page's
 * i18n object, so a string added to the YAML is available to the JavaScript
 * without touching this script. Two things outside it are folded in: the census
 * field labels, which name the inputs of the identification form, and the
 * question numbering used in each ballot legend.
 *
 * @param {Object} tree - one locale's tree.
 * @returns {Object|null} the voting page strings, or null when this locale has none.
 */
const pageStrings = (tree) => {
  const page = dig(tree, "decidim.elections.vocdoni.votes.page");

  if (!page || typeof page !== "object") {
    return null;
  }

  return {
    ...page,
    fields: dig(tree, "decidim.elections.vocdoni.census.fields") || {},
    question_number: dig(tree, "decidim.elections.vocdoni.elections.show.question_number") || ""
  };
};

/**
 * Writes one JSON file per locale, plus the index the voting page reads first.
 *
 * Every locale is merged *over English* so that a partially translated locale
 * can never leave a control unlabelled: the worst case is an English string, not
 * a missing one.
 *
 * @returns {Promise<string[]>} the locales written.
 */
const buildLocales = async () => {
  const trees = await readLocaleTrees();
  const fallback = pageStrings(trees[DEFAULT_LOCALE]);

  if (!fallback) {
    throw new Error(`config/locales carries no ${DEFAULT_LOCALE} voting page strings; the page would have no floor to fall back to`);
  }

  await fs.mkdir(localesOut, { recursive: true });

  const written = [];

  for (const [locale, tree] of Object.entries(trees)) {
    const strings = pageStrings(tree);

    if (!strings) {
      continue;
    }

    const messages = locale === DEFAULT_LOCALE
      ? strings
      : deepMerge(fallback, strings);

    await fs.writeFile(path.join(localesOut, `${locale}.json`), `${JSON.stringify(messages, null, 2)}\n`);
    written.push(locale);
  }

  written.sort();

  await fs.writeFile(
    path.join(localesOut, "index.json"),
    `${JSON.stringify({ default: DEFAULT_LOCALE, locales: written }, null, 2)}\n`
  );

  // A locale file that is no longer generated must not linger and be served.
  const stale = (await fs.readdir(localesOut)).
    filter((name) => name.endsWith(".json") && name !== "index.json").
    filter((name) => !written.includes(path.basename(name, ".json")));

  for (const name of stale) {
    await fs.rm(path.join(localesOut, name));
  }

  return written;
};

/**
 * Bundles the voting page's JavaScript and CSS, and copies the shell.
 *
 * @returns {Promise<void>} nothing.
 */
const buildAssets = async () => {
  await fs.mkdir(output, { recursive: true });
  await fs.copyFile(path.join(source, "vote.html"), path.join(output, "vote.html"));
  // The page used to live at `booth.html`, and links to it were sent to real
  // people. The redirect is generated rather than left behind by hand so that a
  // rebuild cannot quietly drop it.
  await fs.copyFile(path.join(source, "booth_redirect.html"), path.join(output, "booth.html"));

  // Source Sans Pro, the face Decidim itself ships. It is copied rather than
  // linked so the page makes no third-party request: a voting page must not
  // tell a font host that somebody is voting. `vote.css` names these files
  // relative to itself, so they have to land beside it.
  await fs.mkdir(fontsOut, { recursive: true });

  const faces = (await fs.readdir(fontSource)).filter((name) => name.endsWith(".woff2")).sort();

  for (const name of faces) {
    await fs.copyFile(path.join(fontSource, name), path.join(fontsOut, name));
  }

  await esbuild.build({
    entryPoints: [path.join(source, "entry.js")],
    outfile: path.join(output, "vote.js"),
    bundle: true,
    minify: true,
    format: "iife",
    platform: "browser",
    // The voting page runs in whatever the voter has. This floor still supports
    // `URLSearchParams`, `fetch`, optional chaining and BigInt, which the
    // Vocdoni SDK needs for the vote envelope. Safari is pinned to 14.1 rather
    // than 14.0: esbuild treats 14.0's destructuring as broken and refuses to
    // build for it, and it cannot lower destructuring either.
    target: ["chrome80", "firefox78", "safari14.1", "edge88"],
    // Resolves the `src/decidim/...` imports the same way jest's
    // `moduleDirectories` and Shakapacker do, so one import style works
    // everywhere.
    nodePaths: [path.join(root, "app/packs")],
    legalComments: "none",
    // The gem may be checked out inside another repository (it usually is, next
    // to Decidim itself). Without this, esbuild walks up and adopts whatever
    // `tsconfig.json`/`jsconfig.json` it finds there.
    tsconfigRaw: {},
    logLevel: "warning"
  });

  await esbuild.build({
    entryPoints: [path.join(source, "vote.css")],
    outfile: path.join(output, "vote.css"),
    bundle: true,
    minify: true,
    // The `@font-face` sources are copied above and served from beside the
    // stylesheet, so the URLs must survive the bundle untouched rather than
    // being resolved against the source tree.
    external: ["fonts/*"],
    tsconfigRaw: {},
    logLevel: "warning"
  });
};

/**
 * Fails the build if a dependency that must be pinned is not.
 *
 * `@noble/curves` 1.8.1 is an override in `package.json`, and a bundle built
 * against a different version would be wrong in a way nothing else here would
 * notice — the signatures would simply not verify.
 *
 * @returns {void} nothing.
 */
const checkPins = async () => {
  const expected = (require(path.join(root, "package.json")).overrides || {})["@noble/curves"];
  // Read off disk rather than `require`: the package does not export its own
  // `package.json`, and an override is only ever installed at the top level.
  const installed = path.join(root, "node_modules/@noble/curves/package.json");
  const actual = JSON.parse(await fs.readFile(installed, "utf8")).version;

  if (expected && actual !== expected) {
    throw new Error(`@noble/curves is ${actual}, expected the pinned ${expected}. Run npm install.`);
  }
};

await checkPins();

const locales = await buildLocales();

await buildAssets();

process.stdout.write(`voting page built into public/vocdoni (locales: ${locales.join(", ")})\n`);
