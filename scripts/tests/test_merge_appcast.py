#!/usr/bin/env python3
"""验证正式版与开发版共用 appcast 合并器时的版本替换边界。"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class MergeAppcastTests(unittest.TestCase):
    """同一营销版本只保留最新 item，跨营销版本保留历史。"""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write_appcast(self, path: Path, items: list[tuple[str, str, str]]) -> None:
        body = "".join(
            f"""<item>
<sparkle:version>{build}</sparkle:version>
<sparkle:shortVersionString>{marketing}</sparkle:shortVersionString>
<enclosure url="{url}" length="1" />
</item>"""
            for marketing, build, url in items
        )
        path.write_text(
            f'<rss xmlns:sparkle="{SPARKLE_NS}"><channel><title>Starcat</title>{body}</channel></rss>'
        )

    def test_same_marketing_version_replaces_development_with_stable(self):
        base = self.root / "development.xml"
        incoming = self.root / "stable.xml"
        self.write_appcast(
            base,
            [("2.0.0", "202610140900", "https://example.test/v2.0.0-dev.1/dev.dmg")],
        )
        self.write_appcast(
            incoming,
            [("2.0.0", "202610151000", "https://example.test/v2.0.0/stable.dmg")],
        )

        subprocess.run(
            [
                "python3", str(ROOT / "scripts/merge-appcast.py"),
                "--base", str(base), "--incoming", str(incoming), "--output", str(base),
            ],
            check=True,
        )

        items = ET.parse(base).findall("./channel/item")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].find("enclosure").get("url"), "https://example.test/v2.0.0/stable.dmg")

    def test_new_marketing_version_keeps_previous_stable_item(self):
        base = self.root / "development.xml"
        incoming = self.root / "development-current.xml"
        self.write_appcast(
            base,
            [("1.9.0", "202610112000", "https://example.test/v1.9.0/stable.dmg")],
        )
        self.write_appcast(
            incoming,
            [("2.0.0", "202610140900", "https://example.test/v2.0.0-dev.1/dev.dmg")],
        )

        subprocess.run(
            [
                "python3", str(ROOT / "scripts/merge-appcast.py"),
                "--base", str(base), "--incoming", str(incoming), "--output", str(base),
            ],
            check=True,
        )

        versions = [
            item.findtext(f"{{{SPARKLE_NS}}}shortVersionString")
            for item in ET.parse(base).findall("./channel/item")
        ]
        self.assertEqual(versions, ["2.0.0", "1.9.0"])


if __name__ == "__main__":
    unittest.main()
