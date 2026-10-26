# Security tab and Dashboard card: design reference

Source of truth: the Decidim 2026 redesign in Figma, page **"💻 Mòdul Vot Decidim"**
(file `Internal Decidim (2026)`, copy `ei3AAas2RO2tzdrzGmbvd1`, page node `7711:29024`),
built on the Decidim Design System (copy `gZRCJZMVuq4ckYsGWndIiV`). The PNGs in this
folder are the visual targets, exported from Figma at 1536 px wide:

| File | Figma node | What it shows |
|---|---|---|
| `figma-security-simple-selected.png` | `7697:10129` | Security tab, "Simple vote" selected. No one-time-code block. |
| `figma-security-secure-selected.png` | `7701:25885` | Security tab, "Secret, verifiable vote" selected, one-time-code block visible. |
| `figma-dashboard-ended.png` | `7701:27439` | Dashboard of a published, ongoing election with the new "Your security configuration" card. |

Only these three screens exist for elections. The "🚧 WIP" page has no election content.
A `Notification` banner ("Your voting process is secured using … the Vocdoni Protocol …")
exists on the Dashboard frame but is **hidden** in Figma (`7701:27565`, `hidden="true"`): out
of scope.

## Tokens

Every colour and type value on these screens is a Design System variable. Decidim is landing
the same variables as CSS custom properties in
[decidim/decidim#17722](https://github.com/decidim/decidim/pull/17722)
(`decidim-core/app/packs/stylesheets/decidim/tokens/*.css`, generated from Figma through
Supernova). Until that PR is in the Decidim version this module runs on, the variables are
undefined, so every use carries the Figma value as fallback:
`var(--color-color-text-neutral-dark, #303030)`.

| Figma variable | Value | Decidim CSS variable (PR #17722) | Used for |
|---|---|---|---|
| `color/text/neutral/dark` | `#303030` | `--color-color-text-neutral-dark` | body text, option titles, checkbox labels, "Best for:" |
| `color/text/neutral/light` | `#525252` | `--color-color-text-neutral-light` | bullet points, helper text, "Good to know" |
| `color/bg/neutral/dark` | `#fafafa` | `--color-color-bg-neutral-dark` | footer band of the unselected option, checkbox background |
| `color/bg/info/light` | `#e8eff9` | `--color-color-bg-info-light` | footer band of the selected option, "Recommended" pill |
| `color/border/neutral/light` | `#e7e7e7` | `--color-color-border-neutral-light` | card and option borders, section separator |
| `color/border/secondary` | `#155abf` | `--color-color-border-secondary` | selected option border (2 px) |
| `color/icon/neutral/light` | `#525252` | `--color-color-icon-neutral-light` | information icons |
| `color/icon/secondary` | `#155abf` | `--color-color-icon-secondary` | section chevron, shield icon |
| `Secondary/Blue` | `#155abf` | `--secondary` (alias kept by the PR) | section title, pill text, primary actions |
| `typography/fontSize/sm` + `lineHeight/sm` | 14 px / 21 px | `--measure-font-size-typography-fontsize-sm`, `--measure-line-height-typography-lineheight-sm` | points, helper text, notes |
| `typography/fontSize/md` + `lineHeight/md` | 16 px / 24 px | `…-fontsize-md`, `…-lineheight-md` | lead, option titles, 2FA heading |
| radius 8 px | | `--measure-border-radius-border-radius-lg` | outer card, option cards |
| radius 4 px | | `--measure-border-radius-border-radius-sm` | checkbox, dashboard card, buttons |
| space 8 / 16 / 20 / 24 px | | `--measure-space-space-xs` / `-md` / (20 has no token) / `-lg` | gaps and padding |

Spacing and radii are expressed with the standard Tailwind utilities that already carry these
values (`gap-2`, `p-4`, `gap-5`, `gap-6`, `rounded`, `rounded-lg`); the PR maps the Design
System measures onto the same scale, so nothing changes when it lands.

Legacy palette names that also appear in the Figma styles (`Neutrals/500 #737373`,
`Neutrals/900 #171717`, `Neutrals/Gray #6b7280`) belong to Decidim's current admin
components (tabs, dashboard cards, radio borders) and are left to upstream.

## Security tab (nodes `7697:10129`, `7701:25885`)

Layout, top to bottom, inside upstream's `.item__edit-form` column (815 px wide at 1536 px):

1. **Page title** "Edit election" (upstream `item_show__header-title`, Source Sans Pro Bold
   20 px `#020203`), the same title as Main, Questions, Census and Dashboard. Not "Security".
2. **Tabs** (upstream `admin_elections_menu`): unchanged.
3. **One outer card** (`7701:25972`): white, 1 px `border/neutral/light`, radius 8 px,
   padding 16 px, vertical gap 24 px. Everything on the tab lives inside it.
   1. **Section header** (`7701:25973`): a disclosure row, gap 8 px: chevron icon 24 px
      (Remixicon `arrow-down-s-line`, pointing down while the section is open, as in the
      PNG, and rotated to point right when it is closed) + "How do you want to run
      this vote?" in `Secondary/Blue`, SemiBold 16 px; below it a full-width 1 px separator
      (`border/neutral/light`), 8 px under the row.
   2. **Lead** (`7701:25980`): Regular 16 px `text/neutral/dark`.
   3. **Two option cards** side by side, gap 20 px, equal width, equal height
      (`7701:25981`). Each card:
      - white, radius 8 px, padding-top 16 px, body padding-x 16 px, body gap 16 px;
      - **unselected**: 1 px `border/neutral/light`; **selected**: 2 px `border/secondary`;
      - header row, gap 8 px: native radio (16 px, border `#6b7280`, filled secondary when
        checked) + title SemiBold 16/24 `text/neutral/dark`. **No icon.**
      - **no one-line summary** under the title (the "Runs on this platform, like a survey."
        layer exists in Figma but is not laid out; drop it);
      - bullet list: plain `list-disc`, `ms-[21px]`, Regular 14/21 `text/neutral/light`.
        **No icons per point.** Four points per option, same copy as today;
      - footer band, full width, pushed to the bottom of the card (cards stretch to the
        tallest): padding 8 px top, 16 px bottom, 16 px sides, bottom radius 8 px.
        Unselected: bg `bg/neutral/dark`, border `border/neutral/light` (left, right,
        bottom). Selected: bg `bg/info/light`, 2 px `border/secondary` (left, right,
        bottom). Text Regular 14/21 `text/neutral/light`, with "Best for:" in
        `text/neutral/dark`. The secure card's band adds a second paragraph "Powered by the
        Vocdoni voting protocol." (the Figma layer repeats it once more in `#303030`; keep a
        single line).
      - **"Recommended for binding decisions" pill**: sits on the top edge of the secure
        card, right-aligned, overlapping the border (half above, half below). Bg
        `bg/info/light`, text `Secondary/Blue` SemiBold 14 px, padding 2 px 8 px, radius 4 px.
        Not the green `.label.success` pill used today.
   4. **"Good to know"** (`7701:25999`): a plain row, gap 8 px: information icon 20 px
      (`icon/neutral/light`) + text 14/21 `text/neutral/light` with "Good to know:"
      SemiBold. **No box, no background.**
   5. **One-time code block** (`7711:28896`), inside the same outer card, **only rendered
      visible when the secret vote is selected** (absent on the simple-vote screen):
      - heading "Confirm voters' identity with a one-time code", SemiBold 16/24
        `text/neutral/dark` (not a card title);
      - description, Regular 16 px `text/neutral/dark`;
      - two checkbox groups, 24 px apart. Each: row gap 8 px with a native checkbox (16 px,
        radius 4 px, bg `bg/neutral/dark`, border `#737373`) + label Regular 16/22
        `text/neutral/dark`; under it, helper text Regular 14/18 `text/neutral/light`,
        8 px below. **No icons, no bordered option boxes, no "Available for secret,
        verifiable votes" callout.**
      - closing note "If both are on, each voter chooses how to receive the code.": icon 20 px
        + Regular 14/21 `text/neutral/light`, like "Good to know".
4. **Sticky action bar** (`7701:26002`): upstream `item__edit-sticky` with "Save and continue"
   (white button, secondary text). Unchanged.

**Removed from the tab** (not in Figma): the "Why it matters for organisations and public
bodies" disclosure with its four cards and the "At a glance" comparison table; the "Your
configuration" summary line with its level pill (it moves to the Dashboard, see below).

## Dashboard card (node `7701:28224`)

A new card on upstream's Dashboard tab, rendered after the Results card for a published
election and before the Main card for an unpublished one, in the same 815 px column:

- same chrome as the sibling dashboard cards (`card` / `card-divider` / `card-title`): white,
  1 px `border/neutral/light`, radius 4 px, padding 16 px;
- title row, gap 8 px: shield icon 20 px (`icon/secondary`, Remixicon `shield-line`) + "Your
  security configuration" SemiBold 16/22;
- body: one sentence, Regular 14/16 `text/neutral/light`, the current `summary.sentences.*`
  copy for the election's security level ("Anonymous ballots, result checkable by anyone." for
  a secret vote without one-time code).

Upstream's own Dashboard cards (Election status, Calendar, Results, Main, Questions, Census)
are upstream's and are not touched.

## Contrast (WCAG 2.1 AA, measured)

| Pair | Ratio | Use |
|---|---|---|
| `#525252` on `#fafafa` | 7.3:1 | footer band text, helper text |
| `#525252` on `#ffffff` | 7.8:1 | points, notes |
| `#303030` on `#e8eff9` | 10.9:1 | "Best for:" on the selected band |
| `#525252` on `#e8eff9` | 6.6:1 | selected band text |
| `#155abf` on `#e8eff9` | 5.4:1 | "Recommended" pill |
| `#155abf` on `#ffffff` | 6.3:1 | section title |
| `#303030` on `#fafafa` | 12.6:1 | "Best for:" on the unselected band |
| `#155abf` on `#fafafa` | 6.2:1 | guide link on the unselected band |
| `#6b7280` on `#ffffff` | 4.0:1 | radio border (non-text, 3:1 required) |
