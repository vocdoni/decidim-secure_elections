// Decidim's shared Stylelint rules, vendored.
//
// Same reason as `decidim-eslint.cjs`: the published `@decidim/stylelint-config`
// is 0.31 and expects Stylelint 15, while Decidim 0.33 is on Stylelint 17 and
// has not published its config. Copied from
// `packages/stylelint-config/index.js` in decidim/decidim (0.33.0-dev) except
// for `declaration-block-single-line-max-declarations`, which Stylelint 18 does
// not have. Delete it and extend the package once 0.33 is published.

module.exports = { // eslint-disable-line
  "extends": ["stylelint-prettier/recommended"],
  "rules": {
    "at-rule-empty-line-before": [
      "always",
      {
        "except": [
          "blockless-after-same-name-blockless",
          "first-nested"
        ],
        "ignore": [
          "after-comment"
        ],
        "ignoreAtRules": [
          "else"
        ]
      }
    ],
    "block-no-empty": true,
    "color-hex-length": "short",
    "color-no-invalid-hex": true,
    "comment-empty-line-before": [
      "always",
      {
        "except": [
          "first-nested"
        ],
        "ignore": [
          "stylelint-commands"
        ]
      }
    ],
    "comment-no-empty": true,
    "comment-whitespace-inside": "always",
    "custom-property-empty-line-before": [
      "always",
      {
        "except": [
          "after-custom-property",
          "first-nested"
        ],
        "ignore": [
          "after-comment",
          "inside-single-line-block"
        ]
      }
    ],
    "declaration-block-no-duplicate-properties": [
      true,
      {
        "ignore": [
          "consecutive-duplicates-with-different-values"
        ]
      }
    ],
    "declaration-block-no-redundant-longhand-properties": true,
    "declaration-block-no-shorthand-property-overrides": true,
    "declaration-empty-line-before": [
      "always",
      {
        "except": [
          "after-declaration",
          "first-nested"
        ],
        "ignore": [
          "after-comment",
          "inside-single-line-block"
        ]
      }
    ],
    "function-calc-no-unspaced-operator": true,
    "function-linear-gradient-no-nonstandard-direction": true,
    "function-name-case": "lower",
    "keyframe-declaration-no-important": true,
    "length-zero-no-unit": true,
    "media-feature-name-no-unknown": true,
    "no-empty-source": true,
    "no-invalid-double-slash-comments": true,
    "property-no-unknown": true,
    "rule-empty-line-before": [
      "always-multi-line",
      {
        "except": [
          "first-nested"
        ],
        "ignore": [
          "after-comment"
        ]
      }
    ],
    "selector-pseudo-class-no-unknown": true,
    "selector-pseudo-element-colon-notation": "double",
    "selector-pseudo-element-no-unknown": true,
    "selector-type-case": "lower",
    "selector-type-no-unknown": true,
    "shorthand-property-no-redundant-values": true,
    "string-no-newline": true,
    "unit-no-unknown": true
  },
  "overrides": [
    {
      "files": ["**/*.scss"],
      "customSyntax": "postcss-scss"
    }
  ]
}
