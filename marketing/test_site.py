#!/usr/bin/env python3
"""Dependency free checks for the static TerminalDB marketing site."""

from __future__ import annotations

import re
import struct
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent
INDEX = ROOT / "index.html"


class SiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.links: list[str] = []
        self.images: list[dict[str, str]] = []
        self.visible_text: list[str] = []
        self._ignored_depth = 0

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        values = {key: value or "" for key, value in attrs}
        if values.get("id"):
            self.ids.add(values["id"])
        if tag == "a" and values.get("href"):
            self.links.append(values["href"])
        if tag == "img":
            self.images.append(values)
        if tag in {"script", "style", "code", "pre"}:
            self._ignored_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "code", "pre"} and self._ignored_depth:
            self._ignored_depth -= 1

    def handle_data(self, data: str) -> None:
        if not self._ignored_depth and data.strip():
            self.visible_text.append(data)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as file:
        header = file.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{path.relative_to(ROOT)} is not a valid PNG")
    return struct.unpack(">II", header[16:24])


def main() -> None:
    html = INDEX.read_text(encoding="utf-8")
    parser = SiteParser()
    parser.feed(html)

    required_files = [
        ROOT / "support.js",
        ROOT / "vendor/react.production.min.js",
        ROOT / "vendor/react-dom.production.min.js",
        ROOT / "uploads/terminaldb-native-current.png",
        ROOT / "uploads/terminaldb-accounts-current.png",
        ROOT / "favicon.svg",
        ROOT / "_headers",
    ]
    missing = [str(path.relative_to(ROOT)) for path in required_files if not path.is_file()]
    if missing:
        fail(f"missing required files: {', '.join(missing)}")

    forbidden_fragments = [
        "claudeusercontent.com",
        "data-omelette-injected",
        "__om_srcmap",
        "sk-ant-api",
        "/Users/daniel",
        "danny@",
        "tkdan",
        "zsh, bash, fish",
        "Crash reporting is opt in",
        "valid on disk · notarized",
        "Key held in the macOS Keychain",
    ]
    for fragment in forbidden_fragments:
        if fragment.lower() in html.lower():
            fail(f"index.html contains forbidden fragment: {fragment}")

    required_copy = [
        "what worked.",
        "Every Claude account, ready when you need it.",
        "No account limit",
        "Claude subscription",
        "Anthropic API key",
        "https://github.com/danb235/TerminalDB",
        "TerminalDB-macOS.zip",
    ]
    for fragment in required_copy:
        if fragment not in html:
            fail(f"index.html is missing required content: {fragment}")

    if "—" in "".join(parser.visible_text) or "–" in "".join(parser.visible_text):
        fail("visible website copy contains em dash or en dash punctuation")

    for href in parser.links:
        parsed = urlparse(href)
        if href.startswith("#") and href[1:] not in parser.ids:
            fail(f"internal link points to missing id: {href}")
        if parsed.scheme and parsed.scheme not in {"http", "https"}:
            fail(f"unsupported external link scheme: {href}")

    if len(parser.images) != 2:
        fail(f"expected exactly two product screenshots, found {len(parser.images)}")

    expected_images = {
        "uploads/terminaldb-native-current.png": (2056, 1392),
        "uploads/terminaldb-accounts-current.png": (1976, 1332),
    }
    for image in parser.images:
        source = image.get("src", "")
        if source not in expected_images:
            fail(f"unexpected image source: {source}")
        if not image.get("alt", "").strip():
            fail(f"image has no alt text: {source}")
        if not image.get("width") or not image.get("height"):
            fail(f"image has no intrinsic dimensions: {source}")
        actual = png_size(ROOT / source)
        if actual != expected_images[source]:
            fail(f"{source} dimensions are {actual}, expected {expected_images[source]}")
        declared = (int(image["width"]), int(image["height"]))
        if declared != actual:
            fail(f"{source} declares {declared}, actual dimensions are {actual}")

    secret_pattern = re.compile(
        r"(?:sk-ant-api|gh[pousr]_|xox[a-z]-|AKIA[0-9A-Z]{16})",
        re.IGNORECASE,
    )
    for path in ROOT.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".html", ".js", ".md", ".txt"}:
            if secret_pattern.search(path.read_text(encoding="utf-8", errors="ignore")):
                fail(f"possible credential in {path.relative_to(ROOT)}")

    print("Marketing site checks passed.")


if __name__ == "__main__":
    main()
