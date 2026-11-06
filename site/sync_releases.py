"""Refresh the offline website snapshot from the repository's published releases."""

import argparse
import json
from pathlib import Path
import re
import subprocess

RELEASES = "repos/ryekee/Napoleon/releases"


def snapshot(pages, latest, expected=""):
    records = {}
    for page in pages:
        for release in page:
            tag = release["tag_name"]
            if release["draft"] or release["prerelease"] or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
                continue
            version = tag[1:]
            # Earlier releases shipped ZIPs; the site's download buttons promise a DMG.
            if tuple(map(int, version.split("."))) < (0, 3, 1):
                continue
            asset = next((a for a in release["assets"]
                          if a["name"] == f"Napoleon-{version}.dmg" and a["state"] == "uploaded"), None)
            if asset is None:
                raise ValueError(f"{tag}: upload Napoleon-{version}.dmg before deploying the website")
            records[tag] = {
                "version": version, "date": release["published_at"][:10],
                "url": release["html_url"], "download": asset["browser_download_url"],
                "notes": (release["body"] or "").replace("\r\n", "\n"),
            }
    for tag in filter(None, (latest, expected)):
        if tag not in records:
            raise ValueError(f"{tag}: published stable release not found in GitHub's release list")
    # GitHub's Latest flag determines the homepage download, even for a backport.
    return [records[latest], *sorted((r for t, r in records.items() if t != latest),
                                    key=lambda r: tuple(map(int, r["version"].split("."))), reverse=True)]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expect-tag", default="", help="Fail if the triggering release is missing")
    args = parser.parse_args()
    pages = json.loads(subprocess.check_output(["gh", "api", "--paginate", "--slurp", RELEASES + "?per_page=100"]))
    latest = subprocess.check_output(["gh", "api", RELEASES + "/latest", "--jq", ".tag_name"], text=True).strip()
    releases = snapshot(pages, latest, args.expect_tag)
    Path(__file__).with_name("releases.json").write_text(json.dumps(releases, ensure_ascii=False, indent=2) + "\n")
    print(f"Synced {len(releases)} stable DMG releases; latest: {latest}")
