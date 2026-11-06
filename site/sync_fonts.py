#!/usr/bin/env python3
"""Explicitly refresh the local Inter subset; normal builds remain offline.

Run with fonttools[woff]. The font is sourced from Google's official OFL font
repository and cached under build/. Its license is in assets/fonts/Inter-OFL.txt.
"""

from pathlib import Path
import urllib.request

from fontTools import subset
from fontTools.ttLib import TTFont

from site_copy import COPY

ROOT = Path(__file__).resolve().parent
SOURCE = 'https://raw.githubusercontent.com/google/fonts/main/ofl/inter/Inter%5Bopsz,wght%5D.ttf'


def main():
    cache = ROOT.parent / 'build/site-fonts/Inter.ttf'
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.exists():
        # A partial download must not become the cached source for the next run.
        data = urllib.request.urlopen(SOURCE, timeout=30).read()
        cache.write_bytes(data)
    font = TTFont(cache)
    corpus = str(COPY) + ''.join(path.read_text() for path in (ROOT / 'templates').glob('*.html'))
    options = subset.Options()
    options.flavor = 'woff2'
    sub = subset.Subsetter(options=options)
    # Keep Latin letters and diacritics together, plus punctuation used in the copy.
    sub.populate(text=''.join(c for c in corpus if ord(c) < 0x3000), unicodes=range(32, 0x250))
    sub.subset(font)
    font.flavor = 'woff2'
    destination = ROOT / 'assets/fonts/Inter.woff2'
    font.save(destination)
    print(f'Updated {destination}: {destination.stat().st_size} bytes')


if __name__ == '__main__':
    main()
