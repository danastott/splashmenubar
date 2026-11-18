#!/usr/bin/env python3
"""Per-locale localization check (for translators; safe to run in parallel).

Usage: python3 scripts/check_locale.py <locale>   e.g. ... check_locale.py de

Checks one Resources/<locale>.lproj against Resources/en.lproj:
1. Key-set parity (exactly the same keys, no missing, no extra).
2. Every key keeps the same count of format specifiers (%@, %lld, %d) as en.

Exit 0 = pass. The global `make check-i18n` (all locales + source drift)
still runs separately by the maintainer.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "Resources"
EN = RES / "en.lproj"

SPEC = re.compile(r"%\@|%lld|%d")


def unescape(s: str) -> str:
    return (s.replace("\\\\", "\x00")
             .replace('\\"', '"')
             .replace("\\n", "\n")
             .replace("\\t", "\t")
             .replace("\x00", "\\"))


def entries(path: pathlib.Path) -> dict:
    text = path.read_text(encoding="utf-8")
    out = {}
    for m in re.finditer(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;',
                         text, re.M):
        out[unescape(m.group(1))] = unescape(m.group(2))
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[0])
        return 2
    locale = sys.argv[1].removesuffix(".lproj")
    lp = RES / f"{locale}.lproj"
    if not lp.is_dir():
        print(f"FAIL: {lp} does not exist")
        return 1
    en = entries(EN / "Localizable.strings")
    lo = entries(lp / "Localizable.strings")

    missing = set(en) - set(lo)
    extra = set(lo) - set(en)
    bad_spec = {k: (len(SPEC.findall(en[k])), len(SPEC.findall(lo[k])))
                for k in set(en) & set(lo)
                if len(SPEC.findall(en[k])) != len(SPEC.findall(lo[k]))}

    ok = not (missing or extra or bad_spec)
    if missing:
        print(f"FAIL {locale}: {len(missing)} missing key(s), e.g. {sorted(missing)[:5]}")
    if extra:
        print(f"FAIL {locale}: {len(extra)} extra key(s), e.g. {sorted(extra)[:5]}")
    for k, (a, b) in sorted(bad_spec.items()):
        print(f"FAIL {locale}: {k!r} has {b} format specifiers, en has {a}")
    if ok:
        print(f"OK {locale}: {len(lo)} keys, parity + format specifiers")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
