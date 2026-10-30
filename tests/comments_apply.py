#!/usr/bin/env python3
"""Apply translated comment lines to one source file.

Extract:
  py tests/comments_apply.py --extract scripts/enemy.gd > import/enemy.txt

Apply:
  py tests/comments_apply.py --file scripts/enemy.gd --map import/enemy.txt

The map is a text file with "LINE<TAB>comment" rows (1-based line numbers).
Only the comment part of a line is replaced, so code and string literals are
never touched. The final proof is `tests/comments_guard.py`, which compares
the code outside comments with git.

Docstrings in .py files are not handled here: edit them directly.
"""
from __future__ import annotations

import argparse
import re
import sys
import tokenize
import io
from pathlib import Path

CYR = re.compile(r"[А-Яа-яЁё]")


def gd_comment_spans(text: str) -> dict[int, tuple[int, int]]:
    """Map 1-based line number -> (start_col, end_col) of its comment."""
    spans: dict[int, tuple[int, int]] = {}
    n = len(text)
    i = 0
    line = 1
    line_start = 0
    quote = ""
    while i < n:
        ch = text[i]
        if quote == "":
            if ch == "#":
                j = i + 1
                while j < n and text[j] != "\n":
                    j += 1
                spans[line] = (i - line_start, j - line_start)
                i = j
                continue
            if text.startswith('"""', i):
                quote = '"""'
                i += 3
                continue
            if text.startswith("'''", i):
                quote = "'''"
                i += 3
                continue
            if ch in ('"', "'"):
                quote = ch
                i += 1
                continue
            if ch == "\n":
                line += 1
                line_start = i + 1
            i += 1
            continue
        if quote in ('"""', "'''"):
            if text.startswith(quote, i):
                i += 3
                quote = ""
                continue
            if ch == "\\" and i + 1 < n:
                if "\n" in text[i:i + 2]:
                    line += 1
                    line_start = i + 2
                i += 2
                continue
            if ch == "\n":
                line += 1
                line_start = i + 1
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            if "\n" in text[i:i + 2]:
                line += 1
                line_start = i + 2
            i += 2
            continue
        if ch == quote:
            quote = ""
            i += 1
            continue
        if ch == "\n":
            line += 1
            line_start = i + 1
        i += 1
    return spans


def py_comment_spans(text: str) -> dict[int, tuple[int, int]]:
    spans: dict[int, tuple[int, int]] = {}
    for tok in tokenize.generate_tokens(io.StringIO(text).readline):
        if tok.type == tokenize.COMMENT:
            spans[tok.start[0]] = (tok.start[1], tok.end[1])
    return spans


def spans_for(path: Path, text: str) -> dict[int, tuple[int, int]]:
    return py_comment_spans(text) if path.suffix == ".py" else gd_comment_spans(text)


def read_map(path: Path) -> dict[int, str]:
    out: dict[int, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        line_no, _, body = raw.partition("\t")
        out[int(line_no)] = body
    return out


def extract(path: Path, cyr_only: bool, out: Path | None) -> int:
    raw = path.read_bytes().decode("utf-8")
    text = raw.replace("\r\n", "\n")
    lines = text.split("\n")
    spans = spans_for(path, text)
    rows: list[str] = []
    for line_no in sorted(spans):
        start, end = spans[line_no]
        body = lines[line_no - 1][start:end]
        if cyr_only and not CYR.search(body):
            continue
        rows.append(f"{line_no}\t{body}")
    if out is not None:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("\n".join(rows) + "\n", encoding="utf-8")
    else:
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        for row in rows:
            print(row)
    print(f"# {len(rows)} comment line(s) -> {out or 'stdout'}", file=sys.stderr)
    return 0


def apply(path: Path, mapping: dict[int, str], check: bool) -> int:
    raw = path.read_bytes()
    sep = "\r\n" if b"\r\n" in raw else "\n"
    text = raw.decode("utf-8").replace("\r\n", "\n")
    lines = text.split("\n")
    spans = spans_for(path, text)
    errors: list[str] = []
    changed = 0
    for line_no, new_body in sorted(mapping.items()):
        if line_no < 1 or line_no > len(lines):
            errors.append(f"line {line_no}: out of range")
            continue
        span = spans.get(line_no)
        if span is None:
            errors.append(f"line {line_no}: no comment to replace")
            continue
        start, end = span
        old_body = lines[line_no - 1][start:end]
        if not new_body.strip().startswith("#"):
            errors.append(f"line {line_no}: new text does not start with '#'")
            continue
        if new_body == old_body:
            continue
        lines[line_no - 1] = lines[line_no - 1][:start] + new_body + lines[line_no - 1][end:]
        changed += 1
    if errors:
        for err in errors:
            print("ERROR: " + err, file=sys.stderr)
        return 1
    if check:
        print(f"would change {changed} comment line(s) in {path}")
        return 0
    new_text = "\n".join(lines)
    if len(new_text.split("\n")) != len(text.split("\n")):
        print("ERROR: line count changed", file=sys.stderr)
        return 1
    path.write_bytes(new_text.replace("\n", sep).encode("utf-8"))
    print(f"changed {changed} comment line(s) in {path}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", help="source file to edit")
    ap.add_argument("--map", help="map file with LINE<TAB>comment rows")
    ap.add_argument("--extract", help="source file to dump comments from")
    ap.add_argument("--out", help="with --extract: write the map template to this file")
    ap.add_argument("--all", action="store_true", help="with --extract: include English comments")
    ap.add_argument("--check", action="store_true", help="dry run: do not write")
    args = ap.parse_args()

    if args.extract:
        return extract(Path(args.extract), not args.all, Path(args.out) if args.out else None)
    if not args.file or not args.map:
        ap.error("either --extract FILE or --file FILE --map MAP is required")
    return apply(Path(args.file), read_map(Path(args.map)), args.check)


if __name__ == "__main__":
    sys.exit(main())
