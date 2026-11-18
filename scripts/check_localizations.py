#!/usr/bin/env python3
"""Localization sync check for SplashMenuBar (run via `make check-i18n`).

1. Every Resources/<lang>.lproj must have exactly the same key set as
   en.lproj (Localizable.strings plus the top-level keys of
   Localizable.stringsdict, if present).
2. Every *simple* (un-interpolated) string literal in a localizable
   position in Sources/ must exist as a key in en.lproj — this catches
   UI strings added to the code but forgotten in the manifest.
   Interpolated literals are skipped: their keys carry %@ / %lld
   placeholders that this check does not derive.
"""
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "Resources"
EN = RES / "en.lproj"


def unescape(s: str) -> str:
    # Order matters: protect real backslashes first.
    return (s.replace("\\\\", "\x00")
             .replace('\\"', '"')
             .replace("\\n", "\n")
             .replace("\\t", "\t")
             .replace("\x00", "\\"))


def strings_keys(path: pathlib.Path) -> set:
    text = path.read_text(encoding="utf-8")
    return {unescape(m.group(1))
            for m in re.finditer(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', text, re.M)}


def lproj_keys(dirpath: pathlib.Path) -> set:
    keys = set()
    s = dirpath / "Localizable.strings"
    if s.exists():
        keys |= strings_keys(s)
    d = dirpath / "Localizable.stringsdict"
    if d.exists():
        with d.open("rb") as f:
            keys |= set(plistlib.load(f).keys())
    return keys


# Literals that land in a LocalizedStringKey lookup. The value group is the
# raw quoted content (Swift-escaped).
LITERAL_PATTERNS = [
    re.compile(r'Text\("((?:[^"\\]|\\.)*)"\)'),
    re.compile(r'\.help\("((?:[^"\\]|\\.)*)"\)'),
    re.compile(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"\)'),
    re.compile(r'Label\("((?:[^"\\]|\\.)*)",'),
    re.compile(r'LabeledContent\("((?:[^"\\]|\\.)*)"[,)]'),
    re.compile(r'Button\("((?:[^"\\]|\\.)*)"[,)]'),
    re.compile(r'Toggle\("((?:[^"\\]|\\.)*)",'),
    re.compile(r'Picker\("((?:[^"\\]|\\.)*)",'),
    re.compile(r'Section\("((?:[^"\\]|\\.)*)"\)'),
    re.compile(r'accessibilityLabel\("((?:[^"\\]|\\.)*)"\)'),
    re.compile(r'TextField\("((?:[^"\\]|\\.)*)",'),
    # Custom helpers that forward their arguments to Text / .help.
    re.compile(r'sectionLabel\("((?:[^"\\]|\\.)*)",'),
    re.compile(r'\brow\("((?:[^"\\]|\\.)*)",'),
    re.compile(r'help:\s*"((?:[^"\\]|\\.)*)"\)'),
    re.compile(r'caption:\s*"((?:[^"\\]|\\.)*)",'),
]


def main() -> int:
    if not EN.is_dir():
        print("en.lproj missing — nothing to check against", file=sys.stderr)
        return 1
    en_keys = lproj_keys(EN)

    failures = 0

    # 1. Language key-set parity.
    for lproj in sorted(RES.glob("*.lproj")):
        if lproj == EN:
            continue
        lang_keys = lproj_keys(lproj)
        missing = en_keys - lang_keys
        extra = lang_keys - en_keys
        if missing or extra:
            failures += 1
            print(f"{lproj.name}: {len(missing)} missing, {len(extra)} extra "
                  f"(en has {len(en_keys)} keys)")
            for k in sorted(missing):
                print(f"  missing: {k!r}")
            for k in sorted(extra):
                print(f"  extra:   {k!r}")

    # 2. Source literal drift.
    missing = set()
    for src in sorted((ROOT / "Sources").glob("*.swift")):
        text = src.read_text(encoding="utf-8")
        for pat in LITERAL_PATTERNS:
            for m in pat.finditer(text):
                raw = m.group(1)
                if "\\(" in raw:
                    continue  # interpolated — key derivation is out of scope
                key = unescape(raw)
                if key and key not in en_keys:
                    missing.add((src.name, key))
    if missing:
        failures += 1
        print(f"{len(missing)} literal(s) in Sources/ have no key in en.lproj:")
        for name, key in sorted(missing):
            print(f"  {name}: {key!r}")

    if failures:
        return 1
    print(f"OK: {len(list(RES.glob('*.lproj')))} locale(s), "
          f"{len(en_keys)} keys each, all simple source literals covered.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
