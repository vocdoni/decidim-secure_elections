/**
 * The voting page's DOM toolkit.
 *
 * The voting page is a static page, so every control it shows is built here rather
 * than rendered by a server. That moves a real accessibility risk into
 * JavaScript, and this module is where it is contained:
 *
 *   * {@link el} sets text through `textContent` and never through `innerHTML`,
 *     so no value from the API can become markup;
 *   * {@link toggle} uses the `hidden` attribute, which removes an element from
 *     the accessibility tree as well as from the screen;
 *   * {@link focusElement} is called on every step change, so keyboard and
 *     screen-reader users land on the new heading rather than at the top of the
 *     document;
 *   * {@link textParagraphs} turns the API's rich text into plain paragraphs
 *     instead of injecting it.
 *
 * Selectors are ids with a `js-` prefix or `data-` attributes only — never CSS
 * classes, so restyling can never break behaviour.
 */

/**
 * Looks an element up by id.
 *
 * @param {string} id - the element id, without `#`.
 * @returns {Element} the element, or null.
 */
export const byId = (id) => document.getElementById(id);

/**
 * First element matching a selector.
 *
 * @param {string} selector - a CSS selector.
 * @param {Element|Document} scope - the node to search within.
 * @returns {Element} the element, or null.
 */
export const qs = (selector, scope = document) => scope.querySelector(selector);

/**
 * Every element matching a selector, as a real array.
 *
 * @param {string} selector - a CSS selector.
 * @param {Element|Document} scope - the node to search within.
 * @returns {Element[]} the matching elements.
 */
export const qsa = (selector, scope = document) => Array.from(scope.querySelectorAll(selector));

/**
 * Appends children to a node, flattening arrays and skipping nothings, so a
 * builder can write `[condition && node]` without guarding every branch.
 *
 * @param {Element} parent - the node to append to.
 * @param {*} children - a node, a string, or a (nested) array of either.
 * @returns {Element} the parent.
 */
export const append = (parent, children) => {
  const list = Array.isArray(children)
    ? children
    : [children];

  list.forEach((child) => {
    if (child === null || typeof child === "undefined" || child === false || child === true) {
      return;
    }

    if (Array.isArray(child)) {
      append(parent, child);

      return;
    }

    parent.appendChild(typeof child === "string" || typeof child === "number"
      ? document.createTextNode(String(child))
      : child);
  });

  return parent;
};

/**
 * Builds an element.
 *
 * `text` is written with `textContent`: there is deliberately no `html`
 * option, because every string the voting page renders comes from the Vocdoni API or
 * from a translation file and neither is trusted to be markup.
 *
 * @param {string} tag - the tag name.
 * @param {Object} [attrs] - attributes. `text` sets the text content, `dataset`
 *   sets `data-` attributes, `true` renders a bare attribute and
 *   null/undefined/false omit it entirely.
 * @param {*} [children] - anything {@link append} accepts.
 * @returns {Element} the new element.
 */
export const el = (tag, attrs = {}, children = []) => {
  const node = document.createElement(tag);

  Object.entries(attrs || {}).forEach(([name, value]) => {
    if (value === null || typeof value === "undefined" || value === false) {
      return;
    }

    if (name === "text") {
      node.textContent = String(value);

      return;
    }

    if (name === "dataset") {
      Object.entries(value).forEach(([key, item]) => {
        node.dataset[key] = String(item);
      });

      return;
    }

    node.setAttribute(name, value === true
      ? ""
      : String(value));
  });

  return append(node, children);
};

/**
 * Empties a node without touching anything else about it.
 *
 * @param {Element} node - the node to empty.
 * @returns {Element} the node.
 */
export const clear = (node) => {
  if (node) {
    node.textContent = "";
  }

  return node;
};

/**
 * Shows or hides an element using the `hidden` attribute, which — unlike a
 * utility class — also removes it from the accessibility tree.
 *
 * @param {Element} element - the element to show or hide.
 * @param {boolean} visible - true to show it.
 * @returns {void} nothing.
 */
export const toggle = (element, visible) => {
  if (!element) {
    return;
  }

  if (visible) {
    element.removeAttribute("hidden");
  } else {
    element.setAttribute("hidden", "hidden");
  }
};

/**
 * Replaces an element's text content, treating null as an empty string.
 *
 * @param {Element} element - the element to write to.
 * @param {string} text - the text to write.
 * @returns {void} nothing.
 */
export const setText = (element, text) => {
  if (element) {
    element.textContent = typeof text === "string" || typeof text === "number"
      ? String(text)
      : "";
  }
};

/**
 * Disables or enables a control, keeping `aria-disabled` in step.
 *
 * @param {Element} element - the control.
 * @param {boolean} disabled - true to disable it.
 * @returns {void} nothing.
 */
export const setDisabled = (element, disabled) => {
  if (element) {
    element.disabled = Boolean(disabled);
    element.setAttribute("aria-disabled", disabled
      ? "true"
      : "false");
  }
};

/**
 * `%{name}` interpolation, matching the Rails-side message strings so the very
 * same translation works on either side.
 *
 * @param {string} template - the message, with `%{name}` placeholders.
 * @param {Object} values - the values to substitute.
 * @returns {string} the interpolated message.
 */
export const interpolate = (template, values = {}) => String(template || "").
  replace(/%\{(\w+)\}/g, (match, key) => (key in values
    ? String(values[key])
    : match));

/**
 * Moves keyboard focus to `element`. Used on every step change so screen reader
 * and keyboard users land on the new heading instead of the top of the
 * document.
 *
 * @param {Element} element - the element to focus.
 * @returns {void} nothing.
 */
export const focusElement = (element) => {
  if (!element) {
    return;
  }

  if (!element.hasAttribute("tabindex")) {
    element.setAttribute("tabindex", "-1");
  }

  element.focus();
};

/**
 * Turns a value that may contain rich text into plain paragraphs.
 *
 * Question and election descriptions travel to Vocdoni as whatever the admin
 * typed into Decidim's editor, which means they may carry markup. The voting page
 * will not inject that: it parses the value in an inert document and keeps only
 * the text, one string per block. Nothing is executed, nothing is rendered as
 * markup, and the voter still gets readable paragraphs instead of a wall of
 * angle brackets.
 *
 * @param {string} value - the possibly-rich text.
 * @returns {string[]} one string per paragraph, blanks removed.
 */
export const textParagraphs = (value) => {
  const raw = typeof value === "string"
    ? value.trim()
    : "";

  if (raw === "") {
    return [];
  }

  if (!raw.includes("<") || typeof DOMParser === "undefined") {
    return [raw];
  }

  // `DOMParser` with `text/html` builds an inert document: scripts do not run
  // and resources are not fetched. We never adopt any of these nodes.
  const parsed = new DOMParser().parseFromString(raw, "text/html");
  const blocks = Array.from(parsed.body.children).
    map((node) => node.textContent.trim()).
    filter((text) => text !== "");

  return blocks.length > 0
    ? blocks
    : [parsed.body.textContent.trim()].filter((text) => text !== "");
};
