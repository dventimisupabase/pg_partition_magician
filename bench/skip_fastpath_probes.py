#!/usr/bin/env python3
"""Drop pg-lock-tracer's two fastpath lock probes from the installed package (issue #383).

WHY AT ALL. `FastPathGrantRelationLock` is INLINED in the pgdg postgres build: DWARF still mentions
it, but there is no FUNC symbol for libbcc to attach a uprobe to. The tracer has no notion of an
optional probe, so `-t LOCK` fails at attach time and the process exits having traced nothing. This
is the one probe of the nineteen that debug symbols do not rescue.

WHY BOTH OF THEM. The sibling `FastPathUnGrantRelationLock` does resolve. Keeping it while the grant
is structurally invisible would produce a stream carrying fastpath UNGRANTS whose matching GRANTS can
never appear -- a shape that reads exactly like a lock released without being taken, which is the
kind of thing a lock guard exists to notice. Dropping the pair keeps the stream honest about what it
observed.

WHY IT COSTS NOTHING HERE. The fastpath is only ever taken for WEAK locks (RowExclusive and below);
anything at ShareUpdateExclusive or above, AccessExclusive included, always goes through the main
lock table and so through GrantLock/GrantLockLocal, which are untouched. Every property
bench/lock_trace.sh asserts is about AccessExclusive.

Each block must match EXACTLY ONCE or this exits non-zero and takes the image build down with it --
the same discipline bench/mutations/mutate.py follows, and for the same reason. A silent no-op here
would ship an image whose tracer cannot attach, and the failure would surface much later, as a guard
that appears to observe nothing.
"""
import importlib.util
import pathlib
import sys

BLOCKS = [
    """            BPFHelper.register_ebpf_probe(
                self.args.path,
                self.bpf_instance,
                "^FastPathGrantRelationLock$",
                "bpf_lock_fastpath_grant",
                self.args.verbose,
            )
""",
    """            BPFHelper.register_ebpf_probe(
                self.args.path,
                self.bpf_instance,
                "^FastPathUnGrantRelationLock$",
                "bpf_lock_fastpath_ungrant",
                self.args.verbose,
            )
""",
]


def main() -> int:
    spec = importlib.util.find_spec("pg_lock_tracer.pg_lock_tracer")
    if spec is None or spec.origin is None:
        print("skip_fastpath_probes: pg_lock_tracer is not importable", file=sys.stderr)
        return 1

    path = pathlib.Path(spec.origin)
    text = path.read_text()

    for block in BLOCKS:
        got = text.count(block)
        if got != 1:
            print(
                f"skip_fastpath_probes: block matched {got} time(s), expected 1.\n"
                f"  pg-lock-tracer has been refactored and this patch is stale. Fix it -- do NOT let\n"
                f"  the build proceed with the probe still registered, which would leave an image\n"
                f"  whose tracer exits at attach time instead of tracing.\n"
                f"  Block begins: {block.strip().splitlines()[3]!r}",
                file=sys.stderr,
            )
            return 1
        text = text.replace(block, "")

    path.write_text(text)
    print(f"skip_fastpath_probes: patched {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
