<!-- Security fixes are coordinated privately first. See SECURITY.md. -->

## What this changes

<!-- One paragraph. What was wrong or missing, and what it does now. -->

## Why

<!-- Link the issue if there is one. If there is not, say what prompted this. -->

## How to verify

<!-- The steps a reviewer should take. Include the admin and voter sides where both are affected. -->

## Checklist

- [ ] `bundle exec rspec` passes
- [ ] `npm test` passes
- [ ] `bundle exec rubocop`, `npm run lint` and `npm run stylelint` pass
- [ ] If anything under `app/packs/src/decidim/elections/vocdoni/voter/` or the npm
      dependencies changed: `npm run build:booth` was run and `public/vocdoni/`
      is committed
- [ ] New or changed user-facing strings are in `config/locales/en.yml`
- [ ] `CHANGELOG.md` has an entry under *Unreleased*, or this change needs none
- [ ] No secret, ballot, auth token or one-time code can reach a browser, a log
      or persistent storage
- [ ] UI changes meet WCAG 2.1 AA, with contrast measured rather than eyeballed
