#!/usr/bin/env python3
"""Dependency-free release, privacy, and structure checks for the static site."""

from __future__ import annotations

import re
import struct
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
DOWNLOAD = "https://github.com/danb235/TerminalDB/releases/latest/download/TerminalDB-macOS.zip"
SCREENSHOTS = {
    "uploads/terminaldb-native-current.png",
    "uploads/terminaldb-accounts-current.png",
}


class SiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: list[str] = []
        self.links: list[str] = []
        self.images: list[dict[str, str]] = []
        self.stylesheets: list[str] = []
        self.headings: list[int] = []
        self.tags: dict[str, int] = {}
        self.text: list[str] = []
        self.bad_anchors: list[str] = []
        self._anchor: dict[str, str] | None = None
        self._anchor_text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {key: value or "" for key, value in attrs}
        self.tags[tag] = self.tags.get(tag, 0) + 1
        if values.get("id"):
            self.ids.append(values["id"])
        if tag == "a":
            self.links.append(values.get("href", ""))
            self._anchor = values
            self._anchor_text = []
        if tag == "img":
            self.images.append(values)
        if tag == "link" and values.get("rel") == "stylesheet":
            self.stylesheets.append(values.get("href", ""))
        if re.fullmatch(r"h[1-6]", tag):
            self.headings.append(int(tag[1]))

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._anchor is not None:
            if not "".join(self._anchor_text).strip() and not self._anchor.get("aria-label"):
                self.bad_anchors.append(self._anchor.get("href", ""))
            self._anchor = None

    def handle_data(self, data: str) -> None:
        if data.strip():
            self.text.append(data)
        if self._anchor is not None:
            self._anchor_text.append(data)


def check(condition: bool, message: str) -> None:
    if not condition:
        print(f"ERROR: {message}", file=sys.stderr)
        raise SystemExit(1)


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as file:
        header = file.read(24)
    check(len(header) == 24 and header[:8] == b"\x89PNG\r\n\x1a\n", f"invalid PNG: {path.name}")
    return struct.unpack(">II", header[16:24])


def main() -> None:
    html = (ROOT / "index.html").read_text(encoding="utf-8")
    css = (ROOT / "styles.css").read_text(encoding="utf-8")
    headers = (ROOT / "_headers").read_text(encoding="utf-8")
    parser = SiteParser()
    parser.feed(html)
    visible = " ".join(" ".join(parser.text).split())

    check(len(parser.ids) == len(set(parser.ids)), "duplicate element IDs")
    check(parser.headings.count(1) == 1, "expected exactly one h1")
    check(all(b <= a + 1 for a, b in zip(parser.headings, parser.headings[1:])), "heading levels skip a level")
    check(parser.tags.get("main") == 1, "expected one main landmark")
    check(parser.tags.get("details", 0) >= 6, "native FAQ disclosures are missing")
    check(parser.tags.get("details") == parser.tags.get("summary"), "a FAQ disclosure has no summary")
    check(not parser.bad_anchors, f"links without accessible names: {parser.bad_anchors}")
    check('class="skip-link" href="#main"' in html, "keyboard skip link is missing")
    check('<main id="main" tabindex="-1">' in html, "skip destination must accept keyboard focus")
    check('lang="en"' in html, "document language is missing")

    sections = ["remote-access", "claude-accounts", "aws-access", "usage", "product", "security", "download", "faq"]
    positions = [html.find(f'id="{name}"') for name in sections]
    check(all(position >= 0 for position in positions) and positions == sorted(positions), "product sections are missing or out of order")
    check("—" not in visible and "–" not in visible, "visible copy contains em dash or en dash punctuation")

    required_copy = [
        "Your Macs.", "One terminal", "workspace.", "New tabs open locally.",
        "TerminalDB works without an account.", "through your own VPN",
        "complete fingerprints", "approve on both", "TLS 1.3",
        "End Session", "reboot, logout, or session-host failure",
        "Share Sign-In", "next Claude launch", "When LAN or VPN returns",
        "separately on both Macs", "~/.aws/config", "local alias",
        "temporary role credentials", "until AWS expires it",
        "Claude subscription", "Anthropic API key", "not notarized",
        "Apple Silicon (M1 or later)", "macOS 13+", "SHA-256",
        "0.6.7 or earlier", "one-time manual update",
    ]
    for fragment in required_copy:
        check(fragment in visible, f"missing product boundary or feature: {fragment}")

    for fragment in [
        "app.terminaldb.app", "auth.terminaldb.app", "claudeusercontent.com",
        "data-omelette-injected", "__om_srcmap", "/Users/daniel", "danny@", "tkdan",
        "100% secure", "arrives in the next", "releases/download/v0.", "releases/tag/v0.",
        "stelao", "guideline", "192.168.",
        "Apple Silicon + Intel", "universal download", "macOS-universal.zip", "x86_64",
    ]:
        check(fragment.lower() not in html.lower(), f"obsolete, private, or user-specific content: {fragment}")
    check("app.terminaldb.app" not in headers and "auth.terminaldb.app" not in headers, "obsolete cloud endpoint in headers")

    downloads = [link for link in parser.links if "releases/latest/download/" in link]
    check(len(downloads) == 3 and set(downloads) == {DOWNLOAD}, "download CTAs must all use the latest stable asset")
    download_start = html.find('id="download"')
    faq_start = html.find('id="faq"')
    check("0.6.7 or earlier" in html[download_start:faq_start], "manual update guidance must be in the download instructions")
    check("0.6.7 or earlier" not in html[:download_start], "upgrade history must stay out of the primary product introduction")
    for href in parser.links:
        check(bool(href), "empty link destination")
        parsed = urlparse(href)
        if href.startswith("#"):
            check(href[1:] in parser.ids, f"broken local anchor: {href}")
        elif parsed.scheme:
            check(parsed.scheme == "https", f"external link is not HTTPS: {href}")
        else:
            check((ROOT / href).is_file(), f"missing linked local file: {href}")

    check(parser.stylesheets == ["styles.css"], "styles must be local and self-contained")
    check(not any(parser.tags.get(tag) for tag in ["script", "iframe", "form", "x-dc"]), "site must work without scripts, embeds, forms, or generated runtime")
    check("@import" not in css and not re.search(r"url\(\s*['\"]?https?", css), "stylesheet requests external assets")
    for directive in ["script-src 'none'", "connect-src 'none'", "frame-src 'none'", "style-src 'self'", "form-action 'none'"]:
        check(directive in headers, f"missing privacy header: {directive}")
    check("unsafe-eval" not in headers and "unsafe-inline" not in headers, "unnecessary executable CSP exception")
    check(":focus-visible" in css and "prefers-reduced-motion" in css, "keyboard or motion preference styling missing")
    check("max-width: 480px" in css and "max-width: 800px" in css, "mobile/tablet layout rules missing")

    screenshot_sources = {urlparse(image.get("src", "")).path for image in parser.images if image.get("class") == "app-screenshot"}
    check(screenshot_sources == SCREENSHOTS, "expected both current native product screenshots")
    check(len(parser.images) == 3, "expected two screenshots and one decorative logo")
    for image in parser.images:
        source_url = urlparse(image.get("src", ""))
        source = source_url.path
        check((ROOT / source).is_file(), f"missing image: {source}")
        check(bool(image.get("width") and image.get("height")), f"image has no intrinsic dimensions: {source}")
        if source in SCREENSHOTS:
            check(source_url.query == "v=0.6.5", f"screenshot cache version missing: {source}")
            check(bool(image.get("alt", "").strip()), f"screenshot needs alternative text: {source}")
            actual = png_size(ROOT / source)
            declared = (int(image["width"]), int(image["height"]))
            check(declared == actual, f"{source} declares {declared}, actual dimensions are {actual}")
            check(actual[0] >= 1000 and actual[1] >= 600, f"screenshot is too small to show native details: {source}")
        else:
            check(image.get("alt") == "", "decorative wordmark image must not repeat its link label")

    secret_pattern = re.compile(r"(?:sk-ant-api|gh[pousr]_|xox[a-z]-|AKIA[0-9A-Z]{16})", re.IGNORECASE)
    for path in ROOT.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".html", ".css", ".js", ".md", ".txt"}:
            check(not secret_pattern.search(path.read_text(encoding="utf-8", errors="ignore")), f"possible credential in {path.relative_to(ROOT)}")

    print("Marketing site checks passed: structure, accessibility, product boundaries, downloads, assets, and privacy.")


if __name__ == "__main__":
    main()
