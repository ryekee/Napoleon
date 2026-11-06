# Napoleon website

A five-language static website for Napoleon.

## Build and preview

Python 3.9+ is the only build dependency. The build makes no network calls.

```sh
python3 site/build.py
python3 site/check.py
python3 -m http.server 8770 --bind 127.0.0.1 --directory site/dist
```

Open http://127.0.0.1:8770/zh-hans/ for the Chinese homepage, or `/` for English.
The same homepage, FAQ and changelog exist in `/fr/`, `/zh-hant/` and `/ja/`.
Language changes preserve the current page type.

## Edit

- `site_copy.py`: complete English, French, Simplified Chinese, Traditional Chinese and
  Japanese copy, FAQ answers, sample-window labels and editorial release summaries.
- `templates/`: shared navigation/footer and three page layouts.
- `style.css`: responsive marketing layout and sample window previews.
- `demo.js`: local sample selection, app grouping, in-group cycling and search.
- `site.js`: language-menu dismissal and keyboard behavior.
- `releases.json`: an offline snapshot for local previews. CI refreshes it with
  `python3 site/sync_releases.py` before each deployment, without committing it.
- `assets/`: existing Napoleon app icon, local Inter font, Phosphor icons and licenses.
- `sync_fonts.py`: optional Inter subset refresh for added Latin characters.
- `dist/`: generated deployable output, ignored by Git. Do not edit it directly.

Publishing a stable GitHub Release updates the changelog, version and download
buttons. GitHub’s **Latest** release supplies the homepage DMG. The changelog lists
stable DMG releases starting at v0.3.1; it links to GitHub for older ZIP releases.
Upload `Napoleon-X.Y.Z.dmg` to the release draft before publishing `vX.Y.Z`.

Use `## 中文` and `## English` in the approved release notes. New entries use the
matching section, or show the English original with a language label until a
translation is available. Optional headings: `## 繁體中文`, `## Français`, and
`## 日本語`. Text without a language heading is treated as English. The builder
also supports optional per-version editorial summaries in `site_copy.py`.

After adding Latin characters outside the font subset, run
`uv run --with 'fonttools[woff]' python site/sync_fonts.py`, then rebuild. This
explicit refresh downloads Inter from Google's official OFL font repository when
the source is not cached in `build/site-fonts/`. The subset includes French accents
and ligatures. Normal builds and visitors do not contact a font provider.

## Preview behavior

The demo is a browser illustration, not a capture of the user's desktop. It uses
four sample windows across three apps. The two Safari windows form a stack in app
mode. Search matches sample titles, app names and a small set of sample Pinyin
aliases (`gouwu`, `fangda`); it is not a general-purpose Pinyin implementation.

Use the next/previous buttons, arrow keys within the window list, or click a card.
In Apps mode, “Within app” cycles the selected stack. Escape clears search when
the search field is focused, or returns focus to search from a card. ⌘Tab and ⌘`
remain macOS shortcuts and are not intercepted. Sample data stays in memory and
resets on reload. No third-party scripts, telemetry, browser storage or runtime
API requests. Reduced-motion preferences disable transitions.

## Verification

```sh
python3 site/test_releases.py
python3 site/build.py
python3 site/check.py
node --check site/demo.js
node --check site/site.js
git diff --check
```

Also check the actual browser UI: all five locales, narrow widths, language
changes on each page type, search/no results, selection wraparound, grouping,
in-group cycling, FAQ disclosure, release anchors and the download destination.
These checks verify the website, not the native macOS app.

## Deploy

Production: https://napoleon.ryekee.workers.dev/

`wrangler.toml` configures the `napoleon` Worker to serve the files in `site/dist/`.

The [Deploy website workflow](../.github/workflows/website.yml) reads published
releases, builds the site from `main`, checks the result, and deploys it with
Wrangler. Store the target account ID in the repository Actions secret
`CLOUDFLARE_ACCOUNT_ID` and its deployment token in `CLOUDFLARE_API_TOKEN`.
The token needs Workers Scripts Edit access for that account. Only the production
deployment step receives these values.

A tag push, draft, or prerelease does not deploy. Publishing a stable release in
the GitHub UI or with the maintainer’s authenticated `gh` does. If publishing
from another Action using its default `GITHUB_TOKEN`, explicitly dispatch this
workflow: GitHub suppresses follow-on release events from that token.

To check the current live release data without uploading, open **Actions →
Deploy website → Run workflow** on `main` and leave **Deploy to production**
unchecked. Check it to deploy after a correction or to publish a new translation
without creating an app release. A failed sync, build or dry run stops deployment.
