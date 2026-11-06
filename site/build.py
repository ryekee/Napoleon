#!/usr/bin/env python3
"""Build the complete static site offline with Python 3.9+."""

import argparse
from html import escape
import json
from pathlib import Path
import re
import shutil
from urllib.parse import urlsplit

from site_copy import COPY, LOCALES

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "dist"
REPO = "https://github.com/ryekee/Napoleon"
ICON_FILES = {
    "windows": "app-window", "keyboard": "keyboard", "shield": "shield-check",
    "back": "arrow-counter-clockwise", "globe": "globe", "gift": "gift",
    "cpu": "cpu", "download": "download-simple", "faq": "chat-text",
    "changelog": "notebook", "github": "github-logo",
}
ICON_PATHS = {
    "search": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
    "stack": '<path d="m12 3 10 5-10 5L2 8Zm-10 9 10 5 10-5M2 16l10 5 10-5"/>',
    "left": '<path d="M20 12H4m6-6-6 6 6 6"/>',
    "right": '<path d="M4 12h16m-6-6 6 6-6 6"/>',
    "chevron": '<path d="m6 9 6 6 6-6"/>',
    "folder": '<path d="M2 7a2 2 0 0 1 2-2h5l2 2h9a2 2 0 0 1 2 2v10H2Z"/>',
    "safari": '<circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2 5-5 2 2-5Z"/>',
    "notes": '<path d="M5 3h14v18H5zM5 7h14M8 11h8M8 15h8"/>',
    "finder": '<path d="M4 3h16v18H4zM13 3l-3 11h4v7M7 8h.01M17 8h.01M7 16q5 3 10 0"/>',
}


def icon(name):
    if name in ICON_FILES:
        source = (ROOT / "assets/icons" / (ICON_FILES[name] + ".svg")).read_text()
        return source.replace("<svg ", '<svg class="icon" aria-hidden="true" ', 1).replace('stroke-width="24"', 'stroke-width="20"')
    return ('<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
            'stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
            + ICON_PATHS[name] + '</svg>')


def render(template, values):
    return re.sub(r"\{\{([A-Z_]+)\}\}", lambda match: values[match[1]], template)


def route(lang, page=""):
    prefix = LOCALES[lang][0]
    return "/" + "/".join(part for part in (prefix, page) if part) + ("/" if prefix or page else "")


def sample_windows(copy):
    """Visible HTML samples, so the demo is still readable without JavaScript."""
    c = {key: escape(value) for key, value in copy.items() if isinstance(value, str)}
    dots = '<span class="traffic" aria-hidden="true"><i></i><i></i><i></i></span>'
    browser_bar = '<span class="mini-toolbar">' + dots + '<span>example.com</span></span>'
    shopping = ''.join('<span><i aria-hidden="true"></i>' + escape(item) + '</span>' for item in copy['shopping'])
    folders = ''.join('<span>' + icon('folder') + '<small>' + escape(item) + '</small></span>' for item in copy['folders'])
    previews = [
        browser_bar + f'<span class="journal"><small>{c["sample_tag"]}</small><strong>{c["focus_title"]}</strong><span>{c["sample_intro"]}</span><i class="journal-rule"></i><small>{c["sample_bottom"]}</small></span>',
        '<span class="mini-toolbar notes-toolbar">' + dots + '</span>' + f'<span class="note-content"><strong>{c["notes_title"]}</strong>{shopping}</span>',
        '<span class="mini-toolbar">' + dots + f'<span>{c["finder_title"]}</span></span><span class="finder-content"><span class="finder-sidebar" aria-hidden="true"><i></i><i></i><i></i><i></i></span><span class="folder-grid">{folders}</span></span>',
        browser_bar + f'<span class="journal room"><small>{c["sample_tag"]}</small><strong>{c["room_title"]}</strong><i class="journal-rule"></i><span>{c["sample_room"]}</span></span>',
    ]
    samples = [
        ('safari', 'Safari', c['focus_title'], 'focus zhuanzhu 專注 专注'),
        ('notes', {'en': 'Notes', 'fr': 'Notes', 'zh-Hans': '备忘录', 'zh-Hant': '備忘錄', 'ja': 'メモ'}[copy['_lang']], c['notes_title'], 'notes shopping gouwu gouwuqingdan 购物清单 購物清單 beiwanglu'),
        ('finder', {'en': 'Finder', 'fr': 'Finder', 'zh-Hans': '访达', 'zh-Hant': 'Finder', 'ja': 'Finder'}[copy['_lang']], c['finder_title'], 'finder fangda 访达 documents wengao'),
        ('safari', 'Safari', c['room_title'], 'room think kongbai 空白'),
    ]
    cards = []
    for index, ((app, name, title, aliases), preview) in enumerate(zip(samples, previews)):
        cards.append(f'''<button type="button" class="window-card" role="option" aria-selected="{'true' if index == 0 else 'false'}" tabindex="{0 if index == 0 else -1}" data-app="{app}" data-title="{title}" data-aliases="{aliases}" aria-label="{name} — {title}">
          <span class="thumbnail {app} {'article-two' if index == 3 else ''}" aria-hidden="true">{preview}</span>
          <span class="window-label"><span class="app-icon {app}">{icon(app)}</span><span><strong>{name}</strong><span class="window-title">{title}</span></span><span class="stack-count" hidden></span></span>
        </button>''')
    return '\n'.join(cards)


def release_details(release, lang):
    version = release['version']
    editorial = COPY[lang]['releases'].get(version)
    if editorial:
        title, notes = editorial
        return f'<h2>{escape(title)}</h2><ul>' + ''.join('<li>' + escape(n) + '</li>' for n in notes) + '</ul>'

    # Release notes follow the same language headings as the GitHub draft.
    headings = {name: code for code, (_, name, _) in LOCALES.items()}
    headings['中文'] = 'zh-Hans'
    sections = {}
    active = 'en'
    for line in release['notes'].splitlines():
        if line.startswith('## ') and line[3:].strip() in headings:
            active = headings[line[3:].strip()]
        else:
            sections.setdefault(active, []).append(line)
    sections = {code: '\n'.join(lines).strip() for code, lines in sections.items() if any(s.strip() for s in lines)}
    source = lang if lang in sections else 'en' if 'en' in sections else next(iter(sections), lang)
    label = f' · {LOCALES[source][1]}' if source != lang else ''
    html = [f'<h2>Napoleon {escape(version)}{label}</h2>', f'<div lang="{source}">']
    # Only emit our own HTML. Keep unsupported Markdown readable as plain text.
    for block in re.split(r'\n\s*\n', sections.get(source, '')):
        lines = block.splitlines()
        if not lines:
            continue
        if all(line.startswith(('- ', '* ')) for line in lines):
            html.append('<ul>' + ''.join(f'<li>{escape(line[2:])}</li>' for line in lines) + '</ul>')
        elif len(lines) == 1 and lines[0].startswith(('## ', '### ')):
            html.append('<h3>' + escape(block.lstrip('# ')) + '</h3>')
        else:
            html.append('<p>' + '<br>'.join(escape(line) for line in lines) + '</p>')
    return ''.join(html) + '</div>'


def build(origin=""):
    releases = json.loads((ROOT / "releases.json").read_text())
    # Release metadata is the external-data boundary. Never put unvalidated URLs into HTML.
    if not isinstance(releases, list) or not releases:
        raise ValueError("releases.json must contain at least one public release")
    for release in releases:
        version = release.get('version', '')
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise ValueError("Invalid release version")
        if release.get('url') != f"{REPO}/releases/tag/v{version}":
            raise ValueError("Unexpected release URL")
        if release.get('download') != f"{REPO}/releases/download/v{version}/Napoleon-{version}.dmg":
            raise ValueError("Unexpected download URL")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", release.get('date', '')):
            raise ValueError("Invalid release date")
    latest = releases[0]
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "assets").mkdir(parents=True)
    shutil.copytree(ROOT / "assets", OUT / "assets", dirs_exist_ok=True)
    for file in ('style.css', 'site.js', 'demo.js'):
        shutil.copyfile(ROOT / file, OUT / "assets" / file)

    base = (ROOT / "templates/base.html").read_text()
    for lang, (prefix, name, short) in LOCALES.items():
        copy = {**COPY[lang], '_lang': lang}
        for page in ('', 'faqs', 'changelog'):
            # Relative URLs keep the same output portable between static hosts.
            depth = bool(prefix) + bool(page)
            root = '../' * depth or './'
            values = {key.upper(): escape(value) for key, value in copy.items() if isinstance(value, str)}
            for key in ('hero', 'feature_heading', 'feature_intro', 'closing', 'changes_heading'):
                values[key.upper()] = copy[key]
            def href(target_lang, target_page=''):
                return root + route(target_lang, target_page).lstrip('/')
            language_links = []
            for other, (_, label, _) in LOCALES.items():
                current = ' aria-current="true"' if other == lang else ''
                language_links.append(f'<a href="{href(other, page)}" lang="{other}" hreflang="{other}"{current}>{label}</a>')
            values.update({
                'LANG': lang, 'LANG_SHORT': short, 'HOME': href(lang),
                'ASSETS': root + 'assets/', 'DOWNLOAD_URL': escape(latest['download']),
                'FAQ_URL': href(lang, 'faqs'), 'CHANGELOG_URL': href(lang, 'changelog'),
                'VERSION': latest['version'], 'SEO': '',
                'FAQ_CURRENT': 'aria-current="page"' if page == 'faqs' else '',
                'CHANGELOG_CURRENT': 'aria-current="page"' if page == 'changelog' else '',
                'LANG_LINKS': ''.join(language_links),
            })
            values.update({'ICON_' + key.upper(): icon(key) for key in ('faq','changelog','globe','download','chevron','search','left','right')})
            values['FACTS'] = '<ul class="download-facts"><li>' + icon('gift') + escape(copy['free']) + '</li><li>' + icon('windows') + 'macOS 14+</li><li>' + icon('cpu') + 'Apple Silicon &amp; Intel</li></ul>'
            if origin:
                values['SEO'] = f'<link rel="canonical" href="{origin}{route(lang, page)}">\n<meta property="og:url" content="{origin}{route(lang, page)}">\n' + '\n'.join(f'<link rel="alternate" hreflang="{other}" href="{origin}{route(other, page)}">' for other in LOCALES) + f'\n<link rel="alternate" hreflang="x-default" href="{origin}{route("en", page)}">'
            if page == 'faqs':
                values['TITLE'] = escape(copy['faqs'] + ' — Napoleon')
                values['FAQ_ITEMS'] = ''.join(f'<details class="faq"><summary>{escape(q)}{icon("chevron")}</summary><p>{escape(a)}</p></details>' for q, a in copy['faq_items'])
            elif page == 'changelog':
                values['TITLE'] = escape(copy['changelog'] + ' — Napoleon')
                entries = []
                for index, release in enumerate(releases):
                    entries.append(f'''<article class="release" id="v{release['version']}"><div class="release-meta"><a href="#v{release['version']}" class="version">v{release['version']}</a><time datetime="{release['date']}">{release['date'].replace('-', '.')}</time>{'<span class="latest">' + escape(copy['latest']) + '</span>' if index == 0 else ''}</div><div>{release_details(release, lang)}<a class="text-link" href="{release['url']}">{escape(copy['github_release'])}{icon('right')}</a></div></article>''')
                values['RELEASES'] = ''.join(entries)
            else:
                values['WINDOW_CARDS'] = sample_windows(copy)
                values['FEATURES'] = ''.join(f'<article class="feature">{icon(key)}<h3>{escape(title)}</h3><p>{escape(body)}</p></article>' for key, title, body in copy['features'])
                values['DEMO_JSON'] = json.dumps({key: copy[key] for key in ('selected', 'count', 'empty')}, ensure_ascii=False).replace('<', '\\u003c')
            values['BODY'] = render((ROOT / 'templates' / (page or 'home')).with_suffix('.html').read_text(), values)
            destination = OUT / prefix / page / 'index.html'
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(render(base, values))
            if lang == 'en' and page == '':
                values['BODY'] = f'<section class="interior wrap"><h1>{escape(copy["not_found"])}</h1><a class="button" href="/">{escape(copy["back_home"])}</a></section>'
                values['SEO'] = '<meta name="robots" content="noindex">'
                # Error pages may be served at any request depth.
                error_page = render(base, values).replace('href="./', 'href="/').replace('src="./', 'src="/')
                (OUT / '404.html').write_text(error_page)
    if origin:
        urls = [origin + route(lang, page) for lang in LOCALES for page in ('','faqs','changelog')]
        (OUT / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + ''.join('<url><loc>' + url + '</loc></url>' for url in urls) + '</urlset>')
        (OUT / 'robots.txt').write_text(f'User-agent: *\nAllow: /\nSitemap: {origin}/sitemap.xml\n')
    print(f'Built {len(LOCALES) * 3} localized pages + 404 in {OUT}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='', help='Confirmed HTTPS production origin, for canonical URLs and sitemap')
    args = parser.parse_args()
    origin = args.origin.rstrip('/')
    if origin:
        url = urlsplit(origin)
        if url.scheme != 'https' or not url.hostname or url.path or url.query or url.fragment or url.username or url.password or any(c in origin for c in '<>"&'):
            parser.error('--origin must be a plain HTTPS origin')
    build(origin)
