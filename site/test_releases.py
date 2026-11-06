"""Exercise the stable-release selection and the changelog for an untranslated version."""

import unittest

from build import release_details
from sync_releases import snapshot


def github_release(version, **overrides):
    repo = "https://github.com/ryekee/Napoleon"
    return {
        "tag_name": f"v{version}", "draft": False, "prerelease": False,
        "published_at": "2026-11-06T04:00:01Z", "html_url": f"{repo}/releases/tag/v{version}",
        "body": "## 中文\r\n\r\n- 关闭窗口\r\n\r\n## English\r\n\r\n- Close <window>",
        "assets": [{"name": f"Napoleon-{version}.dmg", "state": "uploaded",
                    "browser_download_url": f"{repo}/releases/download/v{version}/Napoleon-{version}.dmg"}],
        **overrides,
    }


class WebsiteReleases(unittest.TestCase):
    def test_pagination_filters_and_github_latest(self):
        pages = [[github_release("1.5.0", draft=True), github_release("1.4.0", prerelease=True), github_release("1.3.0")],
                 [github_release("1.2.0"), github_release("0.3.0", assets=[])]]
        releases = snapshot(pages, "v1.2.0", "v1.3.0")
        self.assertEqual([r["version"] for r in releases], ["1.2.0", "1.3.0"])
        self.assertEqual(releases[0]["date"], "2026-11-06")
        self.assertTrue(releases[0]["download"].endswith("Napoleon-1.2.0.dmg"))

    def test_incomplete_or_missing_release_stops_deploy(self):
        with self.assertRaisesRegex(ValueError, "upload Napoleon-1.0.0.dmg"):
            snapshot([[github_release("1.0.0", assets=[])]], "v1.0.0")
        with self.assertRaisesRegex(ValueError, "v1.1.0"):
            snapshot([[github_release("1.0.0")]], "v1.0.0", "v1.1.0")

    def test_new_version_uses_approved_language_or_marked_fallback(self):
        release, = snapshot([[github_release("1.0.0")]], "v1.0.0")
        chinese = release_details(release, "zh-Hans")
        self.assertIn("<li>关闭窗口</li>", chinese)
        self.assertNotIn("Close", chinese)
        for lang in ("en", "fr", "ja", "zh-Hant"):
            html = release_details(release, lang)
            self.assertIn('<div lang="en"><ul><li>Close &lt;window&gt;</li>', html)
            self.assertEqual(" · English" in html, lang != "en")


if __name__ == "__main__":
    unittest.main()
