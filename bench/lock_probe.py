#!/usr/bin/env python3
"""Observe a maintenance tick's lock boundaries with a purpose-built eBPF probe (issues #383, #389).

Replaces pg-lock-tracer, which this repo used first and then abandoned. That tool emits EVERY lock
event for the whole server through a per-CPU perf buffer and formats each one as JSON in Python. It
cost ~120,000 events per tick to deliver about ten facts, and three of its properties made it unsound
as the basis for a CI guard:

  * the per-CPU perf buffer delivers events out of order across CPUs (measured: 4 inversions in
    101,185 events, two of them statement markers, which moved a QUERY_BEGIN 53,000 positions and
    silently shrank the window under test to nothing);
  * it opens that buffer with no `lost_cb`, so overflow discards events in SILENCE (measured: 4,150
    events lost in one run, with the guard reporting a lock as never released while the commits in
    the same interval proved it had been);
  * the Python consumer cannot keep up at that rate, which is what causes the overflow.

This probe inverts the design. It FILTERS IN THE KERNEL -- only the two relations under test, only
the backends that touched them -- so it emits dozens of events instead of ~120,000, and it uses
BPF_RINGBUF (kernel 5.8+) instead of BPF_PERF_OUTPUT:

  * ONE shared buffer, not one per CPU, so records are visible in reservation order. There is no
    cross-CPU interleaving to sort out, and no `sort(key=timestamp)` anywhere downstream.
  * `ringbuf_reserve()` returns NULL when full, IN THE KERNEL, at the instant of the event. The probe
    counts that itself into `dropped`. Loss is a number this program reports, not an optional
    callback a tool author may forget to pass, so a truncated trace can never masquerade as a
    complete one.

WHAT IT PROBES, and why only these two:

  * `LockRelationOid(Oid relid, LOCKMODE lockmode)` -- both arguments are SCALARS, read straight out
    of the registers. No struct layouts, no version-dependent field offsets.
  * `CommitTransaction(void)` -- the boundary #265 and #279 are written in. Emitted only for a
    backend already seen touching one of the target relations, so other sessions stay invisible.

The release path is deliberately NOT probed. `UnGrantLock(LOCK *lock, ...)` and
`RemoveLocalLock(LOCALLOCK *)` take pointers to structs, so recovering a relation oid from them means
reading fields at offsets that change between PostgreSQL versions -- exactly the fragility this
rewrite exists to escape. A commit releases the lock, so the commit is the honest signal.

Usage: lock_probe.py <oid_a> <oid_b> <output.jsonl>
Prints READY on stdout once probes are attached and the buffer is open -- gate on that, never on
anything printed earlier. Runs until SIGINT, then writes a final `{"dropped": N}` record.
"""
import ctypes
import json
import signal
import sys
import time

from bcc import BPF

BIN = "/usr/lib/postgresql/17/bin/postgres"

BPF_TEXT = r"""
#include <uapi/linux/ptrace.h>

BPF_RINGBUF_OUTPUT(events, 64);
BPF_ARRAY(dropped, u64, 1);
BPF_HASH(watched, u32, u8);

#define KIND_LOCK   0
#define KIND_COMMIT 1

struct ev_t {
    u64 ts;
    u32 pid;
    u32 oid;
    u32 mode;
    u32 kind;
};

static inline void count_drop() {
    int k = 0;
    u64 *d = dropped.lookup(&k);
    if (d) { (*d)++; }
}

int on_lock(struct pt_regs *ctx) {
    u32 oid  = (u32) PT_REGS_PARM1(ctx);
    u32 mode = (u32) PT_REGS_PARM2(ctx);

    /* The whole point: everything irrelevant dies here, in the kernel, and never reaches userspace. */
    if (oid != OID_A && oid != OID_B) { return 0; }

    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u8 one = 1;
    watched.update(&pid, &one);

    struct ev_t *e = events.ringbuf_reserve(sizeof(struct ev_t));
    if (!e) { count_drop(); return 0; }
    e->ts = bpf_ktime_get_ns();
    e->pid = pid;
    e->oid = oid;
    e->mode = mode;
    e->kind = KIND_LOCK;
    events.ringbuf_submit(e, 0);
    return 0;
}

int on_commit(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    /* Only backends already seen touching a relation under test. Every other session stays silent. */
    if (!watched.lookup(&pid)) { return 0; }

    struct ev_t *e = events.ringbuf_reserve(sizeof(struct ev_t));
    if (!e) { count_drop(); return 0; }
    e->ts = bpf_ktime_get_ns();
    e->pid = pid;
    e->oid = 0;
    e->mode = 0;
    e->kind = KIND_COMMIT;
    events.ringbuf_submit(e, 0);
    return 0;
}
"""


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    oid_a, oid_b, out_path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]

    text = BPF_TEXT.replace("OID_A", str(oid_a)).replace("OID_B", str(oid_b))
    b = BPF(text=text)

    # Attach failures must be fatal and legible. A probe that silently did not attach is the same
    # vacuous-pass shape the guards exist to prevent: the stream would simply be missing those events.
    for sym, fn in (("LockRelationOid", "on_lock"), ("CommitTransaction", "on_commit")):
        try:
            b.attach_uprobe(name=BIN, sym=sym, fn_name=fn)
        except Exception as exc:  # noqa: BLE001 -- any failure here is fatal, and the reason matters
            print(f"lock_probe: could not attach {sym}: {exc}", file=sys.stderr)
            return 1

    out = open(out_path, "w")
    running = {"go": True}

    def on_event(ctx, data, size):
        e = b["events"].event(data)
        out.write(json.dumps({
            "ts": e.ts, "pid": e.pid, "oid": e.oid, "mode": e.mode,
            "kind": "lock" if e.kind == 0 else "commit",
        }) + "\n")

    b["events"].open_ring_buffer(on_event)
    signal.signal(signal.SIGINT, lambda *_: running.__setitem__("go", False))
    signal.signal(signal.SIGTERM, lambda *_: running.__setitem__("go", False))

    # Only now is the buffer actually open and delivering. Anything printed before this line would be
    # a promise rather than a fact -- the mistake pg-lock-tracer's "Attaching BPF probes" invites.
    print("READY", flush=True)

    while running["go"]:
        b.ring_buffer_poll(100)
    b.ring_buffer_poll(200)   # final drain

    out.write(json.dumps({"dropped": b["dropped"][ctypes.c_int(0)].value}) + "\n")
    out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
