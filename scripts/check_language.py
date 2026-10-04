#!/usr/bin/env python3
"""Language policy check (run in CI): code, data, schema and documentation are English only.

Arabic text may appear only in interface locale files, which hold the Arabic translation of the interface:
    frontend/src/i18n/ar.ts, backend/app/i18n/ar.json, mobile/src/i18n/ar.ts
Exit status 1 lists every other tracked text file that contains Arabic script.
"""
import re
import subprocess
import sys

ALLOWED = {"frontend/src/i18n/ar.ts", "backend/app/i18n/ar.json", "mobile/src/i18n/ar.ts"}
BINARY = (".docx", ".pdf", ".png", ".jpg", ".jpeg", ".webp", ".ico", ".woff", ".woff2", ".ttf", ".otf", ".zip", ".gz")
# Arabic script blocks, built from code points so this file itself contains no Arabic characters
ARABIC_BLOCKS = [(0x0600, 0x06FF), (0x0750, 0x077F), (0x08A0, 0x08FF), (0xFB50, 0xFDFF), (0xFE70, 0xFEFF)]
ARABIC = re.compile("[" + "".join(f"{chr(a)}-{chr(b)}" for a, b in ARABIC_BLOCKS) + "]")


def main() -> int:
    files = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split("\n")
    bad = []
    for path in filter(None, files):
        if path in ALLOWED or path.lower().endswith(BINARY):
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        lines = [i for i, line in enumerate(text.splitlines(), 1) if ARABIC.search(line)]
        if lines:
            bad.append(f"{path}: lines {', '.join(map(str, lines[:10]))}")
    if bad:
        print("Arabic text outside the interface locale files:\n  " + "\n  ".join(bad))
        return 1
    print("language policy: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
