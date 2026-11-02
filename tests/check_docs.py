#!/usr/bin/env python3
"""
Documentation integrity check: every relative link and image in every
tracked Markdown file must point at something that exists, and every
#anchor must match a heading in the target file (GitHub slug rules).
External http(s) links are not fetched - this runs offline.

Also reports images in docs/images/ that no document references.

Run: make test-docs
"""

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
LINK_RE = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE_RE = re.compile(r"^(```|~~~)")


def markdown_files():
    out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [ROOT / p for p in out.split() if (ROOT / p).exists()]


def strip_code(text, inline=True):
    """Drop fenced code blocks (and, by default, inline code) so example links are ignored."""
    lines, in_fence = [], False
    for line in text.splitlines():
        if FENCE_RE.match(line.strip()):
            in_fence = not in_fence
            lines.append("")
            continue
        lines.append("" if in_fence else re.sub(r"`[^`]*`", "", line) if inline else line)
    return lines


def slug(heading):
    """GitHub-style anchor for a heading."""
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading.strip())  # [text](url) -> text
    s = re.sub(r"[^\w\- ]", "", s.lower())  # drop punctuation, keep word chars/-/space
    return s.replace(" ", "-")


def anchors(path, cache={}):
    if path not in cache:
        found, seen = set(), {}
        for line in strip_code(path.read_text(), inline=False):  # headings keep code text
            m = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
            if m:
                base = slug(m.group(1))
                n = seen.get(base, 0)
                found.add(base if n == 0 else f"{base}-{n}")
                seen[base] = n + 1
        cache[path] = found
    return cache[path]


def main():
    errors, referenced = [], set()
    files = markdown_files()
    for md in files:
        for lineno, line in enumerate(strip_code(md.read_text()), 1):
            for target in LINK_RE.findall(line):
                if re.match(r"^[a-z]+:", target):  # http:, https:, mailto:
                    continue
                path_part, _, frag = target.partition("#")
                dest = md if not path_part else (md.parent / unquote(path_part)).resolve()
                where = f"{md.relative_to(ROOT)}:{lineno}"
                if not dest.exists():
                    errors.append(f"{where}: broken link -> {target}")
                    continue
                referenced.add(dest)
                if frag and dest.suffix == ".md" and frag not in anchors(dest):
                    errors.append(f"{where}: missing anchor #{frag} in {dest.relative_to(ROOT)}")

    images = sorted((ROOT / "docs" / "images").glob("*.png"))
    orphans = [p for p in images if p.resolve() not in referenced]

    print(f"Checked {len(files)} Markdown files, {len(images)} images")
    for o in orphans:
        print(f"  WARN  image not referenced by any doc: {o.relative_to(ROOT)}")
    for e in errors:
        print(f"  FAIL  {e}")
    if errors:
        sys.exit(1)
    print("  PASS  all relative links, images and anchors resolve")


if __name__ == "__main__":
    main()
