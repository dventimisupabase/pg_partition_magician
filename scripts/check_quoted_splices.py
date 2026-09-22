#!/usr/bin/env python3
"""Enforce the `_q` marker on already-quoted SQL fragments. Run by CI (the `Quoted splices` lint job).

WHY THIS EXISTS (issue #409, from the #346 audit). Several functions here build a comma-joined SQL
fragment out of pieces that are already individually `quote_ident`'d, then splice the whole
already-quoted fragment into a larger dynamic query with a bare `%s`:

    select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q from pg_attribute ...
    execute format('insert into %I.%I (%s) select %s from ...', v_nsp, v_child, v_cols_q, v_cols_q, ...)

`%s` is CORRECT there and `%I` would be a bug -- `%I` over an already-quoted string double-quotes it
into garbage, and over a comma-joined list it would quote the commas into the identifier as
well. The problem was never the code; it was that the call site looked
identical either way. Nothing at `format(..., v_cols, ...)` distinguished "already quoted, `%s` on
purpose" from "raw identifier, someone forgot `%I`", so a later edit could swap one for the other in
any of these functions and nothing would look wrong in review.

The `_q` suffix makes the invariant visible where it is used. These two checks keep the suffix
honest in both directions, so that reading it is worth something:

  CHECK 1  a text variable assigned from an identifier-quoting expression MUST end in `_q`.
           Catches the fourth copy of the pattern arriving unmarked -- which is the specific way
           #409 expected this to go wrong.
  CHECK 2  a text variable ending in `_q` MUST be assigned from one. Catches the name outliving its
           value: a refactor that leaves the suffix behind on something no longer quoted is a worse
           outcome than never having marked it, because now the `%s` beside it reads as deliberate.

SCOPE, deliberately narrow. "Identifier-quoting" means the expression itself calls `quote_ident`, or
`format`s with a `%I` (or its positional form `%3$I`), or calls one of QUOTING_HELPERS. A fragment
assembled OUT of `_q` pieces --
`v_elig := format('%1$s >= %2$L', v_ctl_q, v_lo_lit)` -- is not required to be marked: it is a
predicate, not an identifier list, and its provenance is already legible in the `_q` names it is
built from. Widening this to "any pre-built SQL fragment" would put the suffix on nearly every local
in the file, at which point it marks nothing.

Only `text` locals are considered, which is why the declare block is parsed at all: `v_child :=
format('%I.%I', v_nsp, p_child)::regclass` quotes identifiers on its way to an OID, and an OID is not
a fragment anyone can splice wrong.

  ./scripts/check_quoted_splices.py            # check the module
  ./scripts/check_quoted_splices.py --selftest # prove the checks fail when their defect is present
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FILES = [
    "pgpm_core/install.sql",
    "pgpm_hypertable/install.sql",
    "pgpm_archive/install.sql",
]

# Functions that return an already-quoted fragment built from typed inputs. A call to one of these
# is as good as calling quote_ident directly, for CHECK 2's purposes. Adding an entry here is the
# moment a new trusted builder is introduced, which is exactly when it wants a reviewer's eye.
QUOTING_HELPERS = ["archive._pq_from_item", "pgpm._detach_cmd"]

# The floor. A parser that silently stops matching -- a formatting change, a new body delimiter --
# would otherwise report a clean run having examined nothing, which is the one result this script
# must never produce (same reasoning as bench/discriminate.sh's i=0 check).
MIN_QUOTED_ASSIGNMENTS = 12

# `%I`, and the positional form `%3$I` that this module uses wherever an identifier is repeated.
# Both are identifier quoting; missing the positional one would be a silent blind spot rather than
# a loud failure, which is the kind of gap this script exists to close.
SPEC_I = re.compile(r"%(?:\d+\$)?I")


def strip_noise(body: str) -> str:
    """Blank out line comments and the contents of single-quoted strings, KEEPING `%I`.

    Blanking literals is what stops a `;` or a `,` inside one -- `', '`, or a whole dynamic
    statement -- from being read as a statement or select-list boundary, and stops the word
    `select` inside a dynamic statement from looking like a real one. `%I` survives because it is
    the signal: `format('d.%I = s.%I', ...)` quotes identifiers exactly as `quote_ident` does.

    Character-for-character length-preserving, so an offset into the result is an offset into the
    original and reported line numbers are real.
    """
    out = []
    i, n = 0, len(body)
    while i < n:
        c = body[i]
        if c == "'":
            out.append("'")
            i += 1
            while i < n:
                if body[i] == "'":
                    if i + 1 < n and body[i + 1] == "'":   # '' escape inside a literal
                        out.append("  ")
                        i += 2
                        continue
                    out.append("'")
                    i += 1
                    break
                spec = SPEC_I.match(body, i)
                if spec:
                    out.append(spec.group(0))
                    i = spec.end()
                    continue
                out.append(" " if body[i] != "\n" else "\n")
                i += 1
        elif c == "-" and i + 1 < n and body[i + 1] == "-":
            while i < n and body[i] != "\n":
                out.append(" ")
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def split_top_level(text: str, sep: str) -> list:
    """Split on `sep` only where parenthesis depth is zero. Input must already be strip_noise'd."""
    parts, depth, cur, i, n = [], 0, [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if depth == 0 and text.startswith(sep, i):
            parts.append("".join(cur))
            cur = []
            i += len(sep)
            continue
        cur.append(c)
        i += 1
    parts.append("".join(cur))
    return parts


def bodies(text: str):
    """Yield (body_text, offset) for each $$-delimited function body.

    Splitting on `$$` rather than matching CREATE statements: every body in this module is
    dollar-quoted with the bare `$$` tag, and lint.yml's sql-syntax job already requires those to
    balance, so an odd count is somebody else's failure before it is this script's.
    """
    chunks = text.split("$$")
    offset = 0
    for idx, chunk in enumerate(chunks):
        if idx % 2 == 1:                     # odd chunks are inside a $$ ... $$ pair
            yield chunk, offset
        offset += len(chunk) + 2


def declared_types(body: str) -> dict:
    """Map local name -> declared type for the body's top-level DECLARE section."""
    m = re.search(r"(?is)\bdeclare\b(.*?)\bbegin\b", body)
    if not m:
        return {}
    types = {}
    for decl in m.group(1).split(";"):
        decl = re.sub(r"(?s):=.*", "", decl).strip()
        if not decl:
            continue
        parts = decl.split()
        if len(parts) >= 2 and re.fullmatch(r"[a-z_][a-z0-9_]*", parts[0]):
            types[parts[0]] = " ".join(parts[1:]).lower()
    return types


def quotes_identifiers(expr: str) -> bool:
    """The expression itself applies identifier quoting (CHECK 1's trigger)."""
    if "quote_ident(" in expr:
        return True
    if "format(" in expr and SPEC_I.search(expr):
        return True
    return any(h + "(" in expr for h in QUOTING_HELPERS)


def carries_quoting(expr: str) -> bool:
    """The expression's value is quoted, whether it did the quoting or inherited it (CHECK 2)."""
    return quotes_identifiers(expr) or re.search(r"\b[a-z_][a-z0-9_]*_q\b", expr) is not None


# A plpgsql SELECT ... INTO, anywhere in a body, not crossing a statement boundary. Matched by
# regex rather than by splitting the body into statements first, because a chunk split on `;`
# carries whatever block keyword preceded it (`begin`, `then`, `loop`), and requiring a chunk to
# START with `select` silently dropped the first statement of every function.
SELECT_INTO = re.compile(
    r"(?is)\bselect\b(?P<list>[^;]*?)\binto\b\s+(?:strict\s+)?"
    r"(?P<targets>[a-z_][a-z0-9_]*(?:\s*,\s*[a-z_][a-z0-9_]*)*)")

# A plain assignment. Anchored to the start of a line: `:=` also appears in DECLARE initialisers
# and in named-notation arguments (`p_x => ...` does not, but a default does), and a statement in
# this module always begins its own line.
ASSIGN = re.compile(r"(?im)^[ \t]*(?P<target>[a-z_][a-z0-9_]*)\s*:=\s*(?P<expr>[^;]+);")


def assignments(clean: str):
    """Yield (target, expression, match_start) for every plain and SELECT INTO assignment.

    EXECUTE needs no special case: its dynamic statement is blanked by strip_noise, so neither
    pattern can see a `select` or an `:=` inside it, and `execute ... into v_x` therefore yields
    nothing. That is the right answer -- a %I inside a dynamic statement quotes an identifier in
    THAT statement, never in the value coming back through INTO.
    """
    for m in SELECT_INTO.finditer(clean):
        targets = [t.strip() for t in m.group("targets").split(",") if t.strip()]
        exprs = [e.strip() for e in split_top_level(m.group("list"), ",")]
        if len(exprs) != len(targets):
            exprs = [m.group("list")] * len(targets)   # cannot pair them; judge each on the whole list
        for target, expr in zip(targets, exprs):
            yield target, expr, m.start()

    for m in ASSIGN.finditer(clean):
        yield m.group("target"), m.group("expr"), m.start()


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def check_text(path_label: str, text: str):
    """Return (violations, quoted_assignment_count) for one file's text."""
    violations, quoted = [], 0
    for body, offset in bodies(text):
        clean = strip_noise(body)
        types = declared_types(clean)
        for target, expr, pos in assignments(clean):
            if types.get(target, "") != "text":
                continue
            line = line_of(text, offset + pos)
            marked = target.endswith("_q")
            if quotes_identifiers(expr):
                quoted += 1
                if not marked:
                    violations.append(
                        f"{path_label}:{line}  {target} is assigned from an identifier-quoting "
                        f"expression but is not _q-suffixed")
            elif marked and not carries_quoting(expr):
                violations.append(
                    f"{path_label}:{line}  {target} is _q-suffixed but nothing in its assignment "
                    f"quotes an identifier")
    return violations, quoted


CLEAN_FIXTURE = """
create or replace function f() returns void language plpgsql as $$
declare v_nsp name; v_cols_q text; v_child regclass; v_elig text; v_ctl_q text; v_pair_q text;
begin
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q from pg_attribute;
  v_ctl_q := quote_ident('c');
  v_pair_q := format('%1$I = s.%1$I', 'k');
  v_child := format('%I.%I', v_nsp, 't')::regclass;
  v_elig := format('%1$s >= %2$L', v_ctl_q, 'x');
  execute format('insert into %I (%s) select %s', v_nsp, v_cols_q, v_cols_q);
end;
$$;
"""

UNMARKED_FIXTURE = CLEAN_FIXTURE.replace("v_cols_q", "v_cols")
LYING_FIXTURE = CLEAN_FIXTURE.replace("v_elig text", "v_elig_q text").replace("v_elig :=", "v_elig_q :=")


def selftest() -> int:
    """Prove both checks fail when their defect is present. A check only verified against correct
    code is not verified: it is green there whether or not it looks at anything."""
    failures = 0

    v, q = check_text("clean.sql", CLEAN_FIXTURE)
    if v:
        print("SELFTEST FAIL  the clean fixture reported violations:")
        for line in v:
            print("        " + line)
        failures += 1
    elif q != 3:
        print(f"SELFTEST FAIL  the clean fixture should have 3 quoting assignments, saw {q}")
        failures += 1
    else:
        print("SELFTEST PASS  clean fixture: no violations, all three quoting assignments seen "
              "(quote_ident, %I and the positional %1$I)")

    v, _ = check_text("unmarked.sql", UNMARKED_FIXTURE)
    if not any("not _q-suffixed" in x and "v_cols" in x for x in v):
        print("SELFTEST FAIL  check 1 did not catch an unmarked quote_ident'd fragment")
        failures += 1
    else:
        print("SELFTEST PASS  check 1 catches an unmarked quote_ident'd fragment")

    # v_elig_q is built with %L and %s off an already-_q variable, so it inherits quoting and must
    # NOT trip check 2. The lying case is the suffix on something with no quoting anywhere near it.
    v, _ = check_text("lying.sql", LYING_FIXTURE)
    if v:
        print("SELFTEST FAIL  a _q fragment built out of another _q fragment was wrongly flagged:")
        for line in v:
            print("        " + line)
        failures += 1
    else:
        print("SELFTEST PASS  check 2 accepts a _q fragment built out of another _q fragment")

    lying = CLEAN_FIXTURE.replace("v_elig text", "v_elig_q text") \
                         .replace("v_elig := format('%1$s >= %2$L', v_ctl_q, 'x');",
                                  "v_elig_q := 'literally nothing quoted here';")
    v, _ = check_text("lying2.sql", lying)
    if not any("nothing in its assignment" in x and "v_elig_q" in x for x in v):
        print("SELFTEST FAIL  check 2 did not catch a _q suffix on an unquoted value")
        failures += 1
    else:
        print("SELFTEST PASS  check 2 catches a _q suffix on an unquoted value")

    print()
    if failures:
        print("selftest: FAIL")
        return 1
    print("selftest: PASS (both checks fail against their own defect)")
    return 0


def main(argv) -> int:
    if "--selftest" in argv:
        return selftest()

    violations, quoted, missing = [], 0, []
    for rel in FILES:
        path = ROOT / rel
        if not path.is_file():
            missing.append(rel)
            continue
        v, q = check_text(rel, path.read_text())
        violations += v
        quoted += q

    for rel in missing:
        print(f"FAIL  {rel} is missing; it was never checked")
    for line in violations:
        print("FAIL  " + line)

    if quoted < MIN_QUOTED_ASSIGNMENTS:
        print(f"FAIL  only {quoted} identifier-quoting assignment(s) found across {len(FILES)} files, "
              f"expected at least {MIN_QUOTED_ASSIGNMENTS} -- the parser is no longer reading this "
              f"module, so a clean result here means nothing")
        return 1
    if violations or missing:
        return 1
    print(f"PASS  every already-quoted fragment is _q-marked, and every _q name is earned "
          f"({quoted} quoting assignments across {len(FILES)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
