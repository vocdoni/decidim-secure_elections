import { setText } from "src/decidim/elections/vocdoni/voter/dom";

/**
 * Light and dark, and the switch between them.
 *
 * The page follows `prefers-color-scheme` until the voter says otherwise, and
 * keeps following it — a system that flips to dark at sunset flips this page
 * with it — right up to the moment they touch the toggle. From then on their
 * choice wins, for this page, for as long as it is open.
 *
 * **Nothing is persisted.** ARCHITECTURE §0 forbids the voter path from writing to
 * storage, to a cookie or to the URL, and ESLint enforces it. A colour
 * preference is not worth carving the first exception into a rule that exists
 * to keep ballots and auth tokens out of storage — especially on a page that
 * never reloads once it has started, so the choice survives the whole flow
 * anyway.
 *
 * The state is announced by the platform rather than by the page: the control
 * is a real `<button>` with `aria-pressed`, so a screen reader says "Dark
 * theme, toggle button, pressed" without the page writing anything into the
 * live region — which belongs to the flow, not to a preference.
 */

/** The attribute `vote.css` branches on. Absent means "follow the system". */
const ATTRIBUTE = "data-theme";

const DARK_QUERY = "(prefers-color-scheme: dark)";

/**
 * Wires the theme toggle.
 *
 * @param {Object} [options] - dependencies, injectable for tests.
 * @param {Element} [options.button] - the toggle button.
 * @param {Element} [options.label] - the element holding its visible label.
 * @param {Element} [options.root] - the element carrying `data-theme`.
 * @returns {Object} `{ applyLabel }` — the rest is wired to the button.
 */
export const createThemeToggle = ({ button = null, label = null, root = document.documentElement } = {}) => {
  // Null in a browser too old for `matchMedia`; the page then simply starts
  // light and the toggle still works.
  const media = typeof window.matchMedia === "function"
    ? window.matchMedia(DARK_QUERY)
    : null;

  // Null until the voter chooses; while it is null the system decides.
  let chosen = null;

  const systemPrefersDark = () => Boolean(media && media.matches);

  const isDark = () => (chosen === null
    ? systemPrefersDark()
    : chosen === "dark");

  /**
   * Reflects the current theme in the document and on the button.
   *
   * @returns {void} nothing.
   */
  const render = () => {
    if (chosen === null) {
      root.removeAttribute(ATTRIBUTE);
    } else {
      root.setAttribute(ATTRIBUTE, chosen);
    }

    if (button) {
      button.setAttribute("aria-pressed", isDark()
        ? "true"
        : "false");
    }
  };

  /**
   * Names the control once the translations are in. Until then the English
   * floor in `vote.html` stands, because the toggle has to work on the screens
   * that are shown when no translation could be fetched at all.
   *
   * @param {Object} i18n - the loaded translations.
   * @returns {void} nothing.
   */
  const applyLabel = (i18n) => {
    const text = i18n && i18n.theme && i18n.theme.label;

    if (text) {
      setText(label, text);
    }
  };

  if (button) {
    button.addEventListener("click", () => {
      chosen = isDark()
        ? "light"
        : "dark";
      render();
    });
  }

  // Keep following the system until the voter overrides it. `addEventListener`
  // on a MediaQueryList is Safari 14+; older engines simply stop following.
  if (media && typeof media.addEventListener === "function") {
    media.addEventListener("change", () => {
      if (chosen === null) {
        render();
      }
    });
  }

  render();

  return { applyLabel };
};

export default createThemeToggle;
