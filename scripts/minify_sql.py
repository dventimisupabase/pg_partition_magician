#!/usr/bin/env python3
r"""Minify install.sql for the dbdev / TLE package without lying about what it removed.

dbdev caps a package at 250,000 characters and pgpm_core/install.sql is a good deal larger, so the
package is built by dropping what is provably not semantics: blank lines, full-line `--` comments,
and `COMMENT ON` statements. Every one of those decisions depends on knowing where a line SITS
lexically, and the awk this replaces decided each one from the line's own leading characters with no
such knowledge (issue #410).

WHAT WENT WRONG. `stripped ~ /^--/` dropped any line whose trimmed content began with `--`. Inside a
multi-line `'...'` literal -- a statement assembled across several source lines, an example inside a
`raise` message -- that content is DATA, and dropping it changes the SQL an operator installs from
dbdev while install.sql itself, the file that was reviewed and committed, still reads correctly.
Nothing catches it: the script's only check is the 250,000-char ceiling, and a dropped line can only
help pass it. The `COMMENT ON` state machine had the identical blindness, and so did `\ir`/`\i`
expansion.

WHAT THIS DOES INSTEAD. One character-level scanner over the whole file carrying real lexical state:
single-quoted literals (with `''` escapes), double-quoted identifiers, nestable `/* */` block
comments, and a STACK of dollar-quote tags. Each line's decision is made from the state the line
STARTS in. A line that starts inside a literal is emitted byte for byte: not trimmed, not collapsed,
not dropped.

THE ONE JUDGEMENT CALL, and why it is not what #410 sketched. #410 proposed tracking dollar-quote
state and leaving dollar-quoted bodies alone. Measured, that does not fit: comments inside `$$`
bodies are most of what the minifier removes, and leaving them lands the package over the cap. So
this descends INTO dollar-quoted strings and lexes their contents as code, which is what they are
everywhere in this file (PL/pgSQL function bodies, and SQL fragments handed to `execute format`).
The residual, stated rather than hidden: a dollar-quoted string holding non-SQL DATA whose line
begins `--` would still lose that line. There is none today. `./test.sh --channel=dbdev` installs
the minified package and runs the whole pgTAP suite against it, so a corruption that changes
behaviour is caught; one that changes only the text of a generated object would not be.

`\ir`/`\i` expansion is GONE rather than fixed. It had never run -- no source file in this repo uses
either directive -- so it was unverified code standing between the reviewed file and the published
one. A build that meets one now fails loudly instead of expanding it under lexical rules nobody has
ever exercised. scripts/build_install_bundle.sh still inlines includes, and the asymmetry is the
point rather than an oversight: that script copies lines verbatim, where an include boundary costs
nothing, while every decision here depends on lexical state carried across the whole file, which an
include splices something unscanned into the middle of.

Usage:
  scripts/minify_sql.py <src.sql>   # minified SQL on stdout
  scripts/minify_sql.py --selftest  # prove each rule fails when its defect is present
"""

import re
import sys

# A dollar-quote delimiter: `$$` or `$tag$`. Requiring the closing `$` is what keeps this off
# `format`'s positional specs, which are the other thing in this file that looks like `$x`:
# `%1$s` offers `$s` and then a space where the delimiter needs a `$`, so it does not match.
TAG_RE = re.compile(r"\$([A-Za-z_][A-Za-z_0-9]*)?\$")

COMMENT_ON_RE = re.compile(r"(?i)^comment\s+on\s")


class State:
    """Lexical position between two characters of the file."""

    def __init__(self):
        self.squote = False      # inside '...'
        self.dquote = False      # inside "..."
        self.block = 0           # /* */ nesting depth (PostgreSQL nests them)
        self.dollar = []         # open dollar-quote tags, outermost first

    def copy(self):
        s = State()
        s.squote, s.dquote, s.block, s.dollar = self.squote, self.dquote, self.block, list(self.dollar)
        return s

    def in_literal(self):
        return self.squote or self.dquote

    def clean(self):
        return not self.squote and not self.dquote and self.block == 0 and not self.dollar

    def describe(self):
        bits = []
        if self.squote:
            bits.append("an unterminated '...' literal")
        if self.dquote:
            bits.append('an unterminated "..." identifier')
        if self.block:
            bits.append(f"{self.block} unterminated /* */ comment(s)")
        if self.dollar:
            bits.append("unterminated dollar quote(s) " + " ".join(self.dollar))
        return ", ".join(bits)


class LineScan:
    """What scanning one line found, relative to the state it started in."""

    def __init__(self):
        self.comment_at = None   # column where a real `--` comment begins, else None
        self.entered_literal = False
        self.entered_dollar = False
        self.semicolon = False   # a `;` at code level (not inside a literal or comment)


def scan_line(st, line):
    """Advance `st` across `line`, reporting what was found. `st` is mutated."""
    r = LineScan()
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if st.squote:
            if c == "'":
                if line.startswith("''", i):   # a doubled quote is an escaped one, not the end
                    i += 2
                    continue
                st.squote = False
            i += 1
            continue
        if st.dquote:
            if c == '"':
                if line.startswith('""', i):
                    i += 2
                    continue
                st.dquote = False
            i += 1
            continue
        if st.block:
            if line.startswith("*/", i):
                st.block -= 1
                i += 2
                continue
            if line.startswith("/*", i):
                st.block += 1
                i += 2
                continue
            i += 1
            continue
        # Code: at top level, or inside a dollar-quoted string we are lexing as code.
        if line.startswith("--", i):
            r.comment_at = i         # everything after this is comment; state cannot change again
            return r
        if line.startswith("/*", i):
            st.block += 1
            i += 2
            continue
        if c == "'":
            st.squote = True
            r.entered_literal = True
            i += 1
            continue
        if c == '"':
            st.dquote = True
            r.entered_literal = True
            i += 1
            continue
        if c == ";":
            r.semicolon = True
            i += 1
            continue
        if c == "$":
            m = TAG_RE.match(line, i)
            if m:
                tag = m.group(0)
                if st.dollar and st.dollar[-1] == tag:
                    st.dollar.pop()
                else:
                    st.dollar.append(tag)
                r.entered_dollar = True
                i = m.end()
                continue
        i += 1
    return r


def minify(text, origin="<input>"):
    """Return (minified text, lines dropped). Raises ValueError on anything it cannot lex."""
    st = State()
    out = []
    dropped = 0
    in_comment_on = False

    for lineno, line in enumerate(text.split("\n"), start=1):
        before = st.copy()
        scan = scan_line(st, line)

        # A COMMENT ON already under way swallows its continuation lines wherever they sit --
        # including inside its own `is '...'` text, which is why this comes before the literal
        # branch below. The statement ends at a `;` the SCANNER saw at code level, so a `;` inside
        # that text does not end it early (the awk's `;$` line match did, and mis-split there).
        if in_comment_on:
            if scan.semicolon:
                in_comment_on = False
            dropped += 1
            continue

        # Inside a multi-line literal or block comment, the line's leading characters say nothing
        # about what it is. This is the whole of issue #410: emit it exactly as it came in.
        if before.in_literal() or before.block:
            out.append(line)
            continue

        if before.clean() and (line.startswith("\\i ") or line.startswith("\\ir ")):
            raise ValueError(
                f"{origin}:{lineno}: psql include directive in a file being minified.\n"
                f"  Include expansion was removed with #410: it had never run against this repo's\n"
                f"  own source, so its interaction with dollar quotes and literals is unverified.\n"
                f"  Inline the include, or teach this minifier about it deliberately."
            )

        stripped = line.strip()

        if stripped == "":
            dropped += 1
            continue

        # A full-line comment: the `--` is a real comment start (the scanner said so) and nothing
        # but whitespace precedes it. A TRAILING comment leaves its line alone, as it always has.
        if scan.comment_at is not None and line[: scan.comment_at].strip() == "":
            dropped += 1
            continue

        # COMMENT ON, top level only. A dollar-quoted body's contents are code, and a `comment on`
        # there belongs to whatever that code builds, not to this file's own statement stream.
        if not before.dollar and COMMENT_ON_RE.match(stripped):
            if not scan.semicolon:
                in_comment_on = True
            dropped += 1
            continue

        # Collapsing runs of whitespace is only safe where no literal and no dollar delimiter is in
        # play on the line, which is the same bar the awk aimed at and now actually measures.
        if not scan.entered_literal and not scan.entered_dollar:
            stripped = re.sub(r"[ \t]+", " ", stripped)
        out.append(stripped)

    if not st.clean():
        raise ValueError(f"{origin}: reached end of file with {st.describe()}")
    if in_comment_on:
        raise ValueError(f"{origin}: reached end of file inside an unterminated COMMENT ON")
    return "\n".join(out) + "\n", dropped


# ---------------------------------------------------------------------------------------------
# The defect, kept next to the fix. This is a faithful port of the awk #410 is about, used ONLY by
# the self-test: every fixture below has to come out DIFFERENT under it. A fixture both versions
# agree on proves nothing -- it would pass against the broken minifier too, which is the exact
# shape of green this repo keeps having to unlearn.
def _legacy_minify(text):
    out = []
    in_comment_on = False
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped == "":
            continue
        if stripped.startswith("--"):
            continue
        if in_comment_on:
            if re.search(r";[ \t]*$", stripped):
                in_comment_on = False
            continue
        if re.match(r"(COMMENT ON|comment on)[ \t]", stripped):
            if not re.search(r";[ \t]*$", stripped):
                in_comment_on = True
            continue
        if not re.search(r"['\"]|\$\$|\$[A-Za-z_]+\$", stripped):
            stripped = re.sub(r"[ \t]+", " ", stripped)
        out.append(stripped)
    return "\n".join(out) + "\n"


# (name, source, expected output, does the pre-#410 awk get this wrong?)
#
# Both answers to that last field are assertions, and both are load-bearing. `True` is the
# discrimination witness: a fixture the old minifier also gets right would be green against the
# defect and proves nothing. `False` pins behaviour this change deliberately did NOT touch -- the
# comment stripping inside `$$` bodies that the whole 250,000-char budget depends on. Without the
# `False` cases a rewrite could quietly stop stripping and no fixture here would notice.
FIXTURES = [
    (
        "a `--` line inside a multi-line literal is DATA, not a comment",
        "create function f() returns void language plpgsql as $$\n"
        "begin\n"
        "  execute format('create view v as\n"
        "-- kept: this line is inside the literal\n"
        "    select 1');\n"
        "end $$;\n",
        "create function f() returns void language plpgsql as $$\n"
        "begin\n"
        "execute format('create view v as\n"
        "-- kept: this line is inside the literal\n"
        "    select 1');\n"
        "end $$;\n",
        True,
    ),
    (
        "a blank line inside a multi-line literal is DATA too",
        "select 'a\n"
        "\n"
        "b';\n",
        "select 'a\n"
        "\n"
        "b';\n",
        True,
    ),
    (
        "a `comment on` line inside a literal must not arm the stripper",
        "select 'x\n"
        "comment on table t is y\n"
        "kept';\n",
        "select 'x\n"
        "comment on table t is y\n"
        "kept';\n",
        True,
    ),
    (
        "indentation and runs of spaces inside a literal are left alone",
        "select 'a\n"
        "    b     c\n"
        "d';\n",
        "select 'a\n"
        "    b     c\n"
        "d';\n",
        True,
    ),
    (
        "a COMMENT ON whose text holds a `;` ends at the real one, not that one",
        "comment on table t is 'a;\n"
        "b';\n"
        "select 1;\n",
        "select 1;\n",
        True,
    ),
    (
        "a real comment inside a $$ body IS still dropped (most of the savings)",
        "create function f() returns int language plpgsql as $$\n"
        "begin\n"
        "  -- a real plpgsql comment\n"
        "  return 1;\n"
        "end $$;\n",
        "create function f() returns int language plpgsql as $$\n"
        "begin\n"
        "return 1;\n"
        "end $$;\n",
        False,
    ),
    (
        "a nested $q$ closes the inner tag, and the body's own comments still go",
        "create function f() returns int language plpgsql as $$\n"
        "begin\n"
        "  execute $q$\n"
        "    select 1\n"
        "  $q$;\n"
        "  -- dropped: back in the body\n"
        "  return 1;\n"
        "end $$;\n",
        "create function f() returns int language plpgsql as $$\n"
        "begin\n"
        "execute $q$\n"
        "select 1\n"
        "$q$;\n"
        "return 1;\n"
        "end $$;\n",
        False,
    ),
    (
        "a trailing comment leaves its line alone, as it always has",
        "select 1;  -- why\n",
        "select 1; -- why\n",
        False,
    ),
]


def selftest():
    """Prove each rule fails when its defect is present, by running the defect."""
    failures = 0

    for name, src, want, legacy_wrong in FIXTURES:
        try:
            got, _ = minify(src, "fixture")
        except ValueError as exc:
            print(f"SELFTEST FAIL  {name}\n        raised: {exc}")
            failures += 1
            continue
        if got != want:
            print(f"SELFTEST FAIL  {name}\n        got:  {got!r}\n        want: {want!r}")
            failures += 1
            continue
        legacy = _legacy_minify(src)
        if legacy_wrong and legacy == want:
            print(f"SELFTEST FAIL  {name}\n"
                  f"        the pre-#410 minifier produces this too, so the fixture proves nothing")
            failures += 1
            continue
        if not legacy_wrong and legacy != want:
            print(f"SELFTEST FAIL  {name}\n"
                  f"        this was meant to be unchanged behaviour, but the pre-#410 minifier\n"
                  f"        disagrees: {legacy!r}")
            failures += 1
            continue
        print(f"SELFTEST PASS  {name}"
              + ("" if legacy_wrong else "  (unchanged from the pre-#410 minifier, deliberately)"))

    # The tag stack, checked rather than trusted: a nested dollar string inside an open body must
    # close the INNER tag, leaving the body open, and the file must land back at nothing open.
    st = State()
    for line in "as $$\n  execute $q$ select 1 $q$;\n$$;".split("\n"):
        scan_line(st, line)
    if not st.clean():
        print(f"SELFTEST FAIL  balanced nested dollar tags left state dirty: {st.describe()}")
        failures += 1
    else:
        print("SELFTEST PASS  balanced nested dollar tags return to a clean state")

    for bad, what in [("select 'oops;\n", "an unterminated literal"),
                      ("as $$ begin end;\n", "an unterminated dollar quote")]:
        try:
            minify(bad, "fixture")
        except ValueError:
            print(f"SELFTEST PASS  {what} is refused rather than silently minified")
        else:
            print(f"SELFTEST FAIL  {what} was accepted")
            failures += 1

    print()
    if failures:
        print(f"minify_sql selftest: FAIL ({failures} failure(s))")
        return 1
    print(f"minify_sql selftest: PASS ({len(FIXTURES) + 3} check(s))")
    return 0


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        return selftest()
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    src = sys.argv[1]
    with open(src) as fh:
        text = fh.read()
    try:
        out, dropped = minify(text, src)
    except ValueError as exc:
        print(f"minify_sql: {exc}", file=sys.stderr)
        return 1
    # A minifier that removed nothing has stopped reading the file. It would still produce valid
    # SQL and a passing build, just a package over the cap for a reason nobody could see.
    if dropped == 0:
        print(f"minify_sql: {src}: removed no lines at all; the scanner is not reading this file",
              file=sys.stderr)
        return 1
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
