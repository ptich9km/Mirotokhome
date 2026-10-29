#!/usr/bin/env python3
"""Guard for the English-comments migration.

The migration is allowed to change COMMENTS ONLY. This tool compares the
working tree with a git base revision and proves that every changed file keeps
all code and all string literals byte-identical (comments are stripped before
the comparison). The locale table and everything outside the code scope are
protected: changing them is a hard error.

It also reports how many Russian comment lines are left, so batches can be
planned and progress is measurable.

Usage:
  py tests/comments_guard.py                  # check working tree vs origin/master
  py tests/comments_guard.py --all            # check every in-scope file
  py tests/comments_guard.py --files a.gd b.py
  py tests/comments_guard.py --dir scripts/world
  py tests/comments_guard.py --progress --list
  py tests/comments_guard.py --json report.json

Exit code 0 = clean, 1 = a violation was found.
"""
from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import sys
import tokenize
from pathlib import Path

CYR = re.compile(r"[А-Яа-яЁё]")

# Only these paths may change during the migration.
SCOPE = (
    re.compile(r"^scripts/.+\.gd$"),
    re.compile(r"^tests/.+\.gd$"),
    re.compile(r"^tests/.+\.py$"),
)
# Hard protection: the game localization table (ru + en) and its friends.
PROTECTED = (re.compile(r"^assets/locale/"),)
# Supporting files of the migration itself (new files, never comment rewrites).
EXTRA_ALLOWED = {
    "docs/code-glossary.md",
    "docs/comment-suspects.md",
    "tests/comments_guard.py",
}


# ---------------------------------------------------------------- git helpers

def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], capture_output=True, check=False
    )


def load_old_contents(base: str, paths: list[str]) -> dict[str, bytes | None]:
    """Fetch many files at a revision in one git process (git cat-file --batch)."""
    specs = [f"{base}:{rel}" for rel in paths]
    if not specs:
        return {}
    proc = subprocess.run(
        ["git", "cat-file", "--batch"],
        input=("\n".join(specs) + "\n").encode("utf-8"),
        capture_output=True,
        check=False,
    )
    buf = io.BytesIO(proc.stdout)
    out: dict[str, bytes | None] = {}
    for rel in paths:
        header = buf.readline()
        if not header:
            out[rel] = None
            continue
        parts = header.split()
        if len(parts) < 3 or parts[-1] == b"missing":
            out[rel] = None
            continue
        size = int(parts[2])
        out[rel] = buf.read(size)
        buf.read(1)  # trailing LF after the blob
    return out


def _lines(proc: subprocess.CompletedProcess) -> list[str]:
    return [
        line.strip()
        for line in proc.stdout.decode("utf-8", "replace").splitlines()
        if line.strip()
    ]


def changed_paths(base: str) -> list[str]:
    """Tracked changes in the working tree (what the migration itself edits)."""
    return _lines(_git("diff", "--name-only", base))


def untracked_paths() -> list[str]:
    return _lines(_git("ls-files", "--others", "--exclude-standard"))


def tracked_in_scope() -> list[str]:
    files = _lines(_git("ls-files"))
    return [f for f in files if in_scope(f)]


def norm(rel: str) -> str:
    return rel.replace("\\", "/")


def in_scope(rel: str) -> bool:
    return any(rx.match(norm(rel)) for rx in SCOPE)


# ------------------------------------------------------------- GDScript lexer

def gd_split(text: str, strip_shader_comments: bool = False) -> tuple[str, list[tuple[int, str]]]:
    """Return (code without comments, [(line_no, comment_text)]).

    Understands single/double quotes and triple-quoted GDScript strings, so a
    '#' inside a string (e.g. Color("#ff0000")) is not treated as a comment.
    When strip_shader_comments is on, '//...' inside strings is dropped too
    (GLSL comments live inside shader strings in this project).
    """
    text = text.replace("\r\n", "\n")
    code: list[str] = []
    comments: list[tuple[int, str]] = []
    line = 1
    i = 0
    n = len(text)
    quote = ""  # "", "'", '"', "'''", '"""'

    while i < n:
        ch = text[i]
        if quote == "":
            if ch == "#":
                j = i + 1
                while j < n and text[j] != "\n":
                    j += 1
                comments.append((line, text[i:j]))
                i = j
                continue
            if text.startswith('"""', i):
                quote = '"""'
                code.append('"""')
                i += 3
                continue
            if text.startswith("'''", i):
                quote = "'''"
                code.append("'''")
                i += 3
                continue
            if ch in ('"', "'"):
                quote = ch
                code.append(ch)
                i += 1
                continue
            if ch == "\n":
                line += 1
            code.append(ch)
            i += 1
            continue

        # Inside a string literal.
        if strip_shader_comments and text.startswith("//", i):
            j = i + 1
            while j < n and text[j] != "\n":
                j += 1
            i = j
            continue
        if quote in ('"""', "'''"):
            if text.startswith(quote, i):
                code.append(quote)
                i += 3
                quote = ""
                continue
            if ch == "\\" and i + 1 < n:
                pair = text[i:i + 2]
                code.append(pair)
                if "\n" in pair:
                    line += 1
                i += 2
                continue
            if ch == "\n":
                line += 1
            code.append(ch)
            i += 1
            continue
        # Single-line string.
        if ch == "\\" and i + 1 < n:
            pair = text[i:i + 2]
            code.append(pair)
            if "\n" in pair:
                line += 1
            i += 2
            continue
        if ch == quote:
            code.append(ch)
            quote = ""
            i += 1
            continue
        if ch == "\n":
            line += 1
        code.append(ch)
        i += 1

    return "".join(code), comments


# --------------------------------------------------------------- Python lexer

def _significant(tokens: list[tokenize.TokenInfo], start: int, step: int) -> tokenize.TokenInfo | None:
    i = start + step
    while 0 <= i < len(tokens):
        if tokens[i].type not in (tokenize.NL, tokenize.COMMENT, tokenize.ENCODING):
            return tokens[i]
        i += step
    return None


def _is_standalone_string(tokens: list[tokenize.TokenInfo], idx: int) -> bool:
    """True for docstrings and bare string statements."""
    prev = _significant(tokens, idx, -1)
    nxt = _significant(tokens, idx, 1)
    prev_ok = prev is None or prev.type in (tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT)
    next_ok = nxt is None or nxt.type in (tokenize.NEWLINE, tokenize.ENDMARKER)
    return prev_ok and next_ok


def py_split(text: str, allow_docstrings: bool = True) -> tuple[list[tuple[int, str]], list[tuple[int, int, str]]]:
    """Return (comments, docstrings) with line numbers."""
    text = text.replace("\r\n", "\n")
    tokens = list(tokenize.generate_tokens(io.StringIO(text).readline))
    comments = [(t.start[0], t.string) for t in tokens if t.type == tokenize.COMMENT]
    docstrings: list[tuple[int, int, str]] = []
    if allow_docstrings:
        for idx, tok in enumerate(tokens):
            if tok.type == tokenize.STRING and _is_standalone_string(tokens, idx):
                docstrings.append((tok.start[0], tok.end[0], tok.string))
    return comments, docstrings


def py_code(text: str, allow_docstrings: bool = True) -> list[tuple[int, str]]:
    text = text.replace("\r\n", "\n")
    tokens = list(tokenize.generate_tokens(io.StringIO(text).readline))
    keep: list[tuple[int, str]] = []
    for idx, tok in enumerate(tokens):
        if tok.type in (tokenize.COMMENT, tokenize.ENCODING, tokenize.NL):
            continue
        if allow_docstrings and tok.type == tokenize.STRING and _is_standalone_string(tokens, idx):
            continue
        keep.append((tok.type, tok.string))
    return keep


# ------------------------------------------------------------- verification

def line_count(text: str) -> int:
    if not text:
        return 0
    return text.count("\n") + (0 if text.endswith("\n") else 1)


def _first_code_diff(old_lines: list[str], new_lines: list[str]) -> str:
    for i, (a, b) in enumerate(zip(old_lines, new_lines), 1):
        if a != b:
            return f"line {i}: code changed\n    old: {a!r}\n    new: {b!r}"
    if len(old_lines) != len(new_lines):
        return f"code line count: old {len(old_lines)} != new {len(new_lines)}"
    return ""


def verify_file(base: str, rel: str, allow_docstrings: bool, allow_shader: bool,
                old_raw: bytes | None = None) -> list[str]:
    errors: list[str] = []
    path = Path(rel)
    if not path.exists():
        return [f"{rel}: deleted (only comments may change)"]
    new_raw = path.read_bytes()
    if old_raw is None:
        return []  # new file: nothing to compare, scope check covers location
    try:
        old_txt = old_raw.decode("utf-8")
        new_txt = new_raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return [f"{rel}: not UTF-8: {exc}"]

    if line_count(old_txt) != line_count(new_txt):
        errors.append(
            f"{rel}: line count changed ({line_count(old_txt)} -> {line_count(new_txt)}); "
            "translate line-for-line"
        )

    if rel.endswith(".py"):
        old_code = py_code(old_txt, allow_docstrings)
        new_code = py_code(new_txt, allow_docstrings)
        if old_code != new_code:
            old_lines = [f"{t}:{s}" for t, s in old_code]
            new_lines = [f"{t}:{s}" for t, s in new_code]
            errors.append(f"{rel}: code/string literals changed; {_first_code_diff(old_lines, new_lines)}")
    else:
        shader = allow_shader and "shader_type" in old_txt
        old_code, _ = gd_split(old_txt, shader)
        new_code, _ = gd_split(new_txt, shader)
        if old_code != new_code:
            errors.append(
                f"{rel}: code/string literals changed; "
                + _first_code_diff(old_code.split("\n"), new_code.split("\n"))
            )
    return errors


def check_scope(paths: list[str]) -> list[str]:
    errors: list[str] = []
    for rel in paths:
        rel = norm(rel)
        if any(rx.match(rel) for rx in PROTECTED):
            errors.append(f"{rel}: PROTECTED (localization must not change)")
        elif not in_scope(rel) and rel not in EXTRA_ALLOWED:
            errors.append(
                f"{rel}: outside the comment scope (allowed: scripts/**.gd, "
                "tests/**.gd, tests/**.py)"
            )
    return errors


def check_untracked(paths: list[str]) -> list[str]:
    """New files are fine anywhere except the protected locale table."""
    return [
        f"{norm(rel)}: PROTECTED (localization must not change)"
        for rel in paths
        if any(rx.match(norm(rel)) for rx in PROTECTED)
    ]


# ----------------------------------------------------------------- progress

def count_cyrillic_comments(text: str, is_py: bool, allow_docstrings: bool) -> int:
    if is_py:
        comments, docstrings = py_split(text, allow_docstrings)
        lines: set[int] = {ln for ln, body in comments if CYR.search(body)}
        for start, end, body in docstrings:
            for off, body_line in enumerate(body.splitlines()):
                if CYR.search(body_line):
                    lines.add(start + off)
        return len(lines)
    _, comments = gd_split(text)
    return len({ln for ln, body in comments if CYR.search(body)})


def progress(files: list[str], allow_docstrings: bool) -> tuple[dict[str, int], int]:
    report: dict[str, int] = {}
    for rel in files:
        try:
            text = Path(rel).read_bytes().decode("utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        n = count_cyrillic_comments(text, rel.endswith(".py"), allow_docstrings)
        if n:
            report[rel] = n
    return report, sum(report.values())


# ---------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="origin/master", help="git base revision (default: origin/master)")
    ap.add_argument("--files", nargs="+", help="explicit files to verify")
    ap.add_argument("--dir", nargs="+", help="directories to verify")
    ap.add_argument("--all", action="store_true", help="verify every in-scope tracked file")
    ap.add_argument("--progress", action="store_true", help="report remaining Russian comment lines")
    ap.add_argument("--list", action="store_true", help="with --progress: per-file table, biggest first")
    ap.add_argument("--json", help="write the JSON report to this path")
    ap.add_argument("--strict-docstrings", action="store_true", help="docstrings are code (must not change)")
    ap.add_argument("--no-shader-comments", action="store_true", help="'//' inside shader strings is code")
    ap.add_argument("--no-scope-check", action="store_true", help="skip the allowed-paths check")
    args = ap.parse_args()

    allow_docstrings = not args.strict_docstrings
    allow_shader = not args.no_shader_comments
    errors: list[str] = []

    if args.files:
        targets = [norm(f) for f in args.files]
    elif args.dir:
        dirs = [norm(d).rstrip("/") + "/" for d in args.dir]
        targets = [
            rel for rel in tracked_in_scope()
            if any(rel.startswith(d) for d in dirs)
        ]
    elif args.all:
        targets = tracked_in_scope()
    else:
        targets = changed_paths(args.base)

    if not args.no_scope_check:
        scope_candidates = changed_paths(args.base) if not (args.files or args.dir) else targets
        errors += check_scope(scope_candidates)
        errors += check_untracked(untracked_paths())

    if not args.progress:
        old_contents = load_old_contents(args.base, targets)
        for rel in targets:
            errors += verify_file(
                args.base, rel, allow_docstrings, allow_shader,
                old_raw=old_contents.get(rel),
            )

    report: dict[str, object] = {"errors": errors, "checked": len(targets)}
    if args.progress:
        per_file, total = progress(targets, allow_docstrings)
        report["remaining_total"] = total
        report["remaining"] = per_file
        print(f"Russian comment lines left: {total} in {len(per_file)} files")
        if args.list:
            for rel, n in sorted(per_file.items(), key=lambda kv: (-kv[1], kv[0])):
                print(f"  {n:5d}  {rel}")
    if errors:
        print(f"VIOLATIONS: {len(errors)}")
        for err in errors:
            print("  - " + err)
    elif not args.progress:
        print(f"OK: only comments changed in {len(targets)} file(s)")
    if args.json:
        Path(args.json).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
