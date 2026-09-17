#!/usr/bin/env python3
"""Capture a backend's lock sequence for rendering (issue #392).

SEPARATE from bench/lock_probe.py on purpose, and deliberately not shared with it: that probe is what
the CI guard runs, and the guard's instrument must not move when a human tool changes. The BPF C
below is close to identical; the differences are all here, and all deliberate.

  1. The target oids ENLIST a backend rather than select an event. lock_probe.py records only the two
     relations under test; this records everything an enlisted backend locks, which is what a picture
     needs and a pass/fail assertion does not.
  2. oid >= 16384 (FirstNormalObjectId) excludes catalog relations IN THE KERNEL. Measured on the
     design spike: catalogs are 79.9% of a tick's locks, and 1,535 of the 1,642 events inside the
     guard's own 11.1 ms interval. Excluding them is the difference between 16,591 events and 3,347.
  3. Targets live in a BPF_HASH populated from userspace rather than substituted into the source at
     compile time, so any number of relations can be enlisted.
  4. A uretprobe pairs each request with its grant. attach_uprobe fires at function ENTRY, so a bare
     uprobe observes a REQUEST; the distance to the return is the WAIT, which is the one span on the
     figure that is observed rather than inferred.

An unmatched request is COUNTED, never dropped silently: a wait we lost track of must not render as a
zero-length wait, which is the silent-overflow defect wearing a different hat.

The catalog filter lives on the RETURN side, not the request side, and this is deliberate rather than
incidental. `lock_timeout`, `statement_timeout` and `deadlock_timeout` all abort a wait with an ERROR,
and PostgreSQL escapes that with siglongjmp -- the frame is unwound, not returned from, so a
uretprobe's return trampoline never fires. If a catalog request were filtered out before it ever
reached `pending`, an aborted NON-catalog wait's entry would be left stranded there, and since catalog
locks are 76 to 80% of a watched backend's traffic (measured on this project's own fixtures), the very
next `LockRelationOid` return on that pid -- almost certainly a catalog one -- would consume the stale
entry and emit a FABRICATED grant carrying the old oid and mode with the new, meaningless timestamp.
The real lost wait would vanish with no counter incremented at all: silent loss reintroduced by the
interaction of two individually-correct pieces. So `on_lock` tracks EVERY call from a watched backend,
catalog included, and `on_lock_ret` filters on the way out, after consuming whichever entry is there --
a catalog return must pair with and discard its own catalog request, never leave it for something else
to steal.

Never join on pg_backend_pid(). eBPF's bpf_get_current_pid_tgid() reports the pid as seen from the
kernel's initial pid namespace; psql's pg_backend_pid() reports the pid as seen from inside the
container's own pid namespace. Those numbers do not agree, so the enlistment here works purely off
which oids a backend touches, never off an identifier fetched from SQL.
"""
import ctypes
import json
import signal
import sys

from bcc import BPF

BIN = "/usr/lib/postgresql/17/bin/postgres"
FIRST_NORMAL_OBJECT_ID = 16384

BPF_TEXT = r"""
#include <uapi/linux/ptrace.h>

BPF_RINGBUF_OUTPUT(events, 64);
BPF_ARRAY(dropped, u64, 1);
BPF_ARRAY(unmatched, u64, 1);
BPF_HASH(watched, u32, u8);
BPF_HASH(targets, u32, u8);

struct req_t { u64 ts; u32 oid; u32 mode; };
BPF_HASH(pending, u32, struct req_t);

#define KIND_LOCK   0
#define KIND_COMMIT 1

struct ev_t {
    u64 ts;
    u64 wait_ns;
    u32 pid;
    u32 oid;
    u32 mode;
    u32 kind;
};

int on_lock(struct pt_regs *ctx) {
    u32 oid  = (u32) PT_REGS_PARM1(ctx);
    u32 mode = (u32) PT_REGS_PARM2(ctx);
    u32 pid  = bpf_get_current_pid_tgid() >> 32;

    if (targets.lookup(&oid)) { u8 one = 1; watched.update(&pid, &one); }
    if (!watched.lookup(&pid)) { return 0; }
    /* No catalog filter here, deliberately: every call by a watched backend is tracked so entry and
       exit stay paired even when lock_timeout/statement_timeout/deadlock_timeout aborts a wait and
       the uretprobe never fires for it. The filter lives on the return side, below. */

    /* A pending entry still here means the previous request never returned (its wait was aborted by
       a timeout, which unwinds the frame instead of returning through it). Count it rather than
       overwrite it, so a lost wait is reported instead of vanishing -- but only when it was a wait
       this trace would actually have emitted; a stale CATALOG entry is traffic this trace deliberately
       excludes; it is noise, not signal, and must not fill the counter that certifies completeness. */
    struct req_t *prev = pending.lookup(&pid);
    if (prev) {
        if (prev->oid >= FIRST_NORMAL) {
            int k = 0;
            u64 *u = unmatched.lookup(&k);
            if (u) { (*u)++; }
        }
    }
    struct req_t r = {};
    r.ts = bpf_ktime_get_ns();
    r.oid = oid;
    r.mode = mode;
    pending.update(&pid, &r);
    return 0;
}

int on_lock_ret(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    struct req_t *r = pending.lookup(&pid);
    if (!r) { return 0; }

    /* Read the fields out and consume the entry before deciding whether to emit: a catalog return
       must pair with and discard its OWN catalog request, never leave it in the map for a later,
       unrelated return to steal and misreport as its own. */
    u64 req_ts = r->ts;
    u32 req_oid = r->oid;
    u32 req_mode = r->mode;
    pending.delete(&pid);

    if (req_oid < FIRST_NORMAL) { return 0; }   /* paired and discarded, never emitted */

    struct ev_t *e = events.ringbuf_reserve(sizeof(struct ev_t));
    if (!e) {
        int k = 0;
        u64 *d = dropped.lookup(&k);
        if (d) { (*d)++; }
        return 0;
    }
    e->ts = bpf_ktime_get_ns();
    e->wait_ns = e->ts - req_ts;
    e->pid = pid;
    e->oid = req_oid;
    e->mode = req_mode;
    e->kind = KIND_LOCK;
    events.ringbuf_submit(e, 0);
    return 0;
}

int on_commit(struct pt_regs *ctx) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (!watched.lookup(&pid)) { return 0; }

    struct ev_t *e = events.ringbuf_reserve(sizeof(struct ev_t));
    if (!e) {
        int k = 0;
        u64 *d = dropped.lookup(&k);
        if (d) { (*d)++; }
        return 0;
    }
    e->ts = bpf_ktime_get_ns();
    e->wait_ns = 0;
    e->pid = pid;
    e->oid = 0;
    e->mode = 0;
    e->kind = KIND_COMMIT;
    events.ringbuf_submit(e, 0);
    return 0;
}
"""


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    oids = [int(x) for x in sys.argv[1].split(",") if x]
    out_path = sys.argv[2]

    b = BPF(text=BPF_TEXT.replace("FIRST_NORMAL", str(FIRST_NORMAL_OBJECT_ID)))

    # Populated BEFORE the probes attach, so no event can arrive against an empty target set.
    targets = b["targets"]
    for oid in oids:
        targets[ctypes.c_uint(oid)] = ctypes.c_ubyte(1)

    # Attach failures must be fatal and legible. A probe that silently did not attach is the same
    # vacuous-pass shape the guards exist to prevent, and the uretprobe here is new to this repo: if
    # it fails to attach, that must be loud rather than inferred from missing wait_ns later.
    attachments = (
        ("LockRelationOid", "on_lock", b.attach_uprobe),
        ("LockRelationOid", "on_lock_ret", b.attach_uretprobe),
        ("CommitTransaction", "on_commit", b.attach_uprobe),
    )
    for sym, fn, attach in attachments:
        try:
            attach(name=BIN, sym=sym, fn_name=fn)
        except Exception as exc:  # noqa: BLE001 -- fatal, and the reason matters
            print(f"lock_view: could not attach {fn} to {sym}: {exc}", file=sys.stderr)
            return 1

    out = open(out_path, "w")
    running = {"go": True}

    def on_event(ctx, data, size):
        e = b["events"].event(data)
        out.write(json.dumps({
            "ts": e.ts, "pid": e.pid, "oid": e.oid, "mode": e.mode,
            "kind": "lock" if e.kind == 0 else "commit", "wait_ns": e.wait_ns,
        }) + "\n")

    b["events"].open_ring_buffer(on_event)
    signal.signal(signal.SIGINT, lambda *_: running.__setitem__("go", False))
    signal.signal(signal.SIGTERM, lambda *_: running.__setitem__("go", False))

    # Only now are the probes attached AND the ring buffer open. Nothing may gate on anything
    # printed earlier; READY is the only honest signal that events cannot yet be missed.
    print("READY", flush=True)

    while running["go"]:
        b.ring_buffer_poll(100)
    b.ring_buffer_poll(200)

    # Requests still pending at teardown never got a grant either. Counting them here, rather than
    # letting them evaporate, is what keeps "unmatched" honest. Filtered the same way as on_lock's own
    # stale-entry check (Ruling 13): a pending CATALOG request is traffic this trace deliberately
    # excludes, so it must not inflate the counter that certifies the trace's completeness.
    stale_pending = sum(
        1 for _, v in b["pending"].items() if v.oid >= FIRST_NORMAL_OBJECT_ID
    )
    unmatched = b["unmatched"][ctypes.c_int(0)].value + stale_pending
    out.write(json.dumps({"dropped": b["dropped"][ctypes.c_int(0)].value,
                          "unmatched": unmatched}) + "\n")
    out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
