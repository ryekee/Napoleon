#!/usr/bin/env python3
"""Check generated routes, fragments, assets, headings, translations and release coverage."""

from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

from site_copy import COPY, LOCALES

ROOT = Path(__file__).resolve().parent / 'dist'


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.path = path
        self.ids = set()
        self.links = []
        self.h1 = 0
        self.lang = None
        self.errors = []
        self.feed(path.read_text())

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == 'html':
            self.lang = attrs.get('lang')
        if tag == 'h1':
            self.h1 += 1
        if tag == 'img' and 'alt' not in attrs:
            self.errors.append('Image without alt')
        if 'id' in attrs:
            if attrs['id'] in self.ids:
                self.errors.append('Duplicate ID: ' + attrs['id'])
            self.ids.add(attrs['id'])
        for key in ('href', 'src'):
            if key in attrs:
                self.links.append(attrs[key])


def check():
    errors = []
    paths = list(ROOT.rglob('*.html'))
    expected_pages = len(LOCALES) * 3
    if len(paths) != expected_pages + 1:
        errors.append(f'Expected {expected_pages} localized pages + 404; found {len(paths)}')
    pages = {path: Page(path) for path in paths}
    for lang in LOCALES:
        if COPY[lang].keys() != COPY['en'].keys():
            errors.append(f'{lang}: incomplete translation keys')
    link_count = 0
    for path, page in pages.items():
        errors.extend(f'{path.relative_to(ROOT)}: {error}' for error in page.errors)
        if page.h1 != 1 or page.lang not in LOCALES:
            errors.append(f'{path}: invalid heading count or language')
        if re.search(r'\{\{[A-Z_]+\}\}', path.read_text()):
            errors.append(f'{path}: unresolved template token')
        for link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            target = (ROOT / unquote(url.path).lstrip('/')) if url.path.startswith('/') else (path.parent / unquote(url.path))
            target = target.resolve() if url.path else path
            if target.is_dir():
                target /= 'index.html'
            if not target.is_file():
                errors.append(f'{path.relative_to(ROOT)}: missing target {link}')
            elif url.fragment and target in pages and unquote(url.fragment) not in pages[target].ids:
                errors.append(f'{path.relative_to(ROOT)}: missing fragment {link}')
            link_count += 1
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'PASS: {len(pages)} pages, {len(LOCALES)} complete locales, {link_count} local links/assets/fragments')


if __name__ == '__main__':
    check()
