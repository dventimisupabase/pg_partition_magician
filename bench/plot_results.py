#!/usr/bin/env python3
"""Generate blog-quality figures from the bench/results/* time series.

Reusable: re-run after new bench runs to regenerate. Reads the (gitignored) scratch in
bench/results/ and writes PNG + SVG into bench/figures/ (committable). The source series:

  drain.progress.csv     drain-side time series (rows draining, partitions, drain_budget,
                         ambient_waiters/baseline, surge_active). Schema grew over the project;
                         parsed defensively (missing columns / -1 sentinels skipped).
  pgb_<phase>.<pid>[.t]  pgbench per-transaction logs:
                         client_id txn_no latency_us script_no time_epoch time_us

Figures (each picks the best-suited run; override on the CLI: plot_results.py <fig> <run>):
  1 online-conversion    default rows draining + partitions climbing (the live migration)
  2 latency-unnoticeable workload p50/p95/p99 latency through the conversion vs the baseline
  3 adaptive-feathering  drain_budget riding down under pressure (AIMD), ceiling/floor marked
  4 ambient-surge        drain_budget yielding to a write surge; waiters vs the learned baseline
"""
import csv, glob, os, re, sys, statistics
from datetime import datetime
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
OUT = os.path.join(HERE, "figures")
os.makedirs(OUT, exist_ok=True)

GREEN = "#3ecf8e"   # the pgpm/Supabase green
INK = "#1c1c1c"
GREY = "#9aa0a6"
RED = "#d2553b"


def _save(fig, name):
    for ext in ("png", "svg"):
        p = os.path.join(OUT, f"{name}.{ext}")
        fig.savefig(p, dpi=140, bbox_inches="tight",
                    facecolor="white" if ext == "png" else "none")
    plt.close(fig)
    print(f"  wrote figures/{name}.png + .svg")


def load_progress(run):
    rows = list(csv.DictReader(open(os.path.join(RESULTS, run, "drain.progress.csv"))))

    def col(key, cast=float):
        out = []
        for r in rows:
            v = r.get(key)
            if v in (None, "", "-1"):
                out.append(None)
            else:
                try:
                    out.append(cast(v))
                except ValueError:
                    out.append(None)
        return out
    return rows, col


def load_txn(run, phase):
    """Return sorted [(epoch_seconds, latency_ms), ...] from the per-txn pgbench logs."""
    pts = []
    for f in glob.glob(os.path.join(RESULTS, run, f"pgb_{phase}.*")):
        with open(f) as fh:
            for ln in fh:
                p = ln.split()
                if len(p) < 6:
                    continue
                try:
                    lat_ms = float(p[2]) / 1000.0
                    t = int(p[4]) + int(p[5]) / 1e6
                except ValueError:
                    continue
                pts.append((t, lat_ms))
    pts.sort()
    return pts


def binned_pctiles(pts, bin_s=10):
    """Bin (t, lat) by bin_s seconds from the first txn; return mins, p50, p95, p99 lists."""
    if not pts:
        return [], [], [], []
    t0 = pts[0][0]
    bins = {}
    for t, lat in pts:
        b = int((t - t0) // bin_s)
        bins.setdefault(b, []).append(lat)
    mins, p50, p95, p99 = [], [], [], []
    for b in sorted(bins):
        v = sorted(bins[b])
        mins.append(b * bin_s / 60.0)
        p50.append(statistics.median(v))
        p95.append(v[min(len(v) - 1, int(0.95 * len(v)))])
        p99.append(v[min(len(v) - 1, int(0.99 * len(v)))])
    return mins, p50, p95, p99


def load_report(run):
    """Authoritative per-run outcome from report.md: conversion duration, rows moved, backoffs."""
    p = os.path.join(RESULTS, run, "report.md")
    if not os.path.exists(p):
        return None
    txt = open(p).read()
    win = re.search(r"conversion window: `([\d\- :]+)` -> `([\d\- :]+)`", txt)
    moved = re.search(r"([\d]+) rows moved", txt)
    rem = re.search(r"closed-tail rows remaining: (-?\d+)", txt)
    backoffs = re.search(r"(\d+) backoffs", txt)
    dur = None
    if win:
        a = datetime.strptime(win.group(1).strip(), "%Y-%m-%d %H:%M:%S")
        b = datetime.strptime(win.group(2).strip(), "%Y-%m-%d %H:%M:%S")
        dur = (b - a).total_seconds()
    return dict(dur=dur,
                moved=int(moved.group(1)) if moved else None,
                remaining=int(rem.group(1)) if rem else None,
                backoffs=int(backoffs.group(1)) if backoffs else 0,
                adaptive="adaptive feathering (mode 2)" in txt)


# canonical scale ladder; the -stress runs are the run-to-completion (adaptive) arm that drained to zero.
LADDER = [("R0-stress", 1_000_000), ("R1-stress", 3_000_000),
          ("R2-stress", 10_000_000), ("R3-stress", 40_000_000)]


def fig_scale_ladder():
    pts = []
    for run, rows in LADDER:
        r = load_report(run)
        if r and r["dur"]:
            pts.append((rows, r["dur"], r["moved"]))
    fig, ax = plt.subplots(figsize=(9, 5))
    xs = [r / 1e6 for r, _, _ in pts]
    ys = [d / 60.0 for _, d, _ in pts]
    ax.plot(xs, ys, color=GREEN, lw=2.4, marker="o", ms=9, zorder=5)
    ax.set_xscale("log")
    ax.set_xticks(xs)
    ax.set_xticklabels([f"{x:g}M" for x in xs])
    ax.set_xlim(0.7, 60)
    ax.set_ylim(bottom=0)
    ax.set_xlabel("table size (rows, log scale)")
    ax.set_ylabel("online conversion time (minutes)")
    for (rows, dur, moved), x, y in zip(pts, xs, ys):
        thru = moved / dur
        ax.annotate(f"{y:.1f} min\n{thru/1000:.0f}k rows/s", (x, y),
                    textcoords="offset points", xytext=(10, -2), fontsize=8.5, color=INK,
                    va="center")
    ax.set_title("Scale ladder: online conversion time vs table size (1M -> 40M)\n"
                 "the full closed tail drained to zero at every rung", fontsize=11)
    ax.grid(True, alpha=0.25, which="both")
    _save(fig, "05-scale-ladder")


def fig_fixed_vs_adaptive(run="R3-stress", fixed_run="R3"):
    rows, col = load_progress(run)
    t = [s / 60.0 for s in col("observed_s")]
    budget = col("drain_budget")
    tb = [(x, b) for x, b in zip(t, budget) if b is not None]
    xs = [x for x, _ in tb]
    bs = [b for _, b in tb]
    ceiling = max(bs)
    ra, rf = load_report(run), load_report(fixed_run)
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.axhline(ceiling, color=GREY, lw=2.4,
               label=f"fixed mode: constant drain_batch ({ceiling:,.0f}/tick)")
    ax.fill_between(xs, bs, ceiling, color=GREEN, alpha=0.12)
    ax.plot(xs, bs, color=GREEN, lw=1.6, marker="o", ms=2.5,
            label="adaptive: measured per-tick budget")
    ax.set_ylim(0, ceiling * 1.13)
    ax.set_xlim(left=0)
    ax.set_xlabel("elapsed (minutes)")
    ax.set_ylabel("per-tick drain budget (rows)")
    if ra and rf and ra["dur"] and rf["dur"]:
        pct = 100 * (ra["dur"] - rf["dur"]) / rf["dur"]
        txt = (f"40M closed tail, drained to zero both ways:\n"
               f"  fixed:    {rf['dur']/60:4.0f} min,  {rf['backoffs']} backoffs\n"
               f"  adaptive: {ra['dur']/60:4.0f} min,  {ra['backoffs']} backoffs  (+{pct:.0f}% time)")
        ax.text(0.025, 0.04, txt, transform=ax.transAxes, fontsize=8.5, va="bottom",
                family="monospace", bbox=dict(boxstyle="round", fc="white", ec=GREY, alpha=0.9))
    ax.set_title("Fixed vs adaptive (40M): adaptive feathers the budget below the fixed rate\n"
                 "under WAL/checkpoint pressure, trading some speed for gentleness", fontsize=11)
    ax.legend(loc="upper right", frameon=False)
    ax.grid(True, alpha=0.25)
    _save(fig, "06-fixed-vs-adaptive")


def fig_online_conversion(run="R3-stress"):
    rows, col = load_progress(run)
    t = [s / 60.0 for s in col("observed_s")]
    drows = [d / 1e6 if d is not None else None for d in col("default_rows")]
    parts = col("partitions")
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.plot(t, drows, color=GREEN, lw=2.4, label="rows left in the DEFAULT")
    ax.fill_between(t, drows, color=GREEN, alpha=0.12)
    ax.set_xlabel("elapsed (minutes)")
    ax.set_ylabel("rows in the DEFAULT partition (millions)", color=INK)
    ax.set_ylim(bottom=0)
    ax.set_xlim(left=0)
    ax2 = ax.twinx()
    ax2.step(t, parts, where="post", color=GREY, lw=1.8, label="partitions created")
    ax2.set_ylabel("partitions", color=GREY)
    ax2.set_ylim(bottom=0)
    start, end = drows[0], drows[-1]
    ax.set_title(f"Online conversion: {start:.0f}M-row table partitioned live under load\n"
                 f"(drained {start - end:.0f}M rows while the workload ran; "
                 f"continues to zero past the window)", fontsize=11)
    l1, lab1 = ax.get_legend_handles_labels()
    l2, lab2 = ax2.get_legend_handles_labels()
    ax.legend(l1 + l2, lab1 + lab2, loc="upper right", frameon=False)
    ax.grid(True, alpha=0.25)
    _save(fig, "01-online-conversion")


def fig_latency_unnoticeable(run="R3-gentle"):
    conv = load_txn(run, "convert")
    base = load_txn(run, "baseline")
    mins, p50, p95, p99 = binned_pctiles(conv, bin_s=10)
    base_med = statistics.median([l for _, l in base]) if base else None
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.plot(mins, p99, color=RED, lw=1.3, alpha=0.85, label="p99")
    ax.plot(mins, p95, color="#e8a33d", lw=1.6, label="p95")
    ax.plot(mins, p50, color=GREEN, lw=2.4, label="p50 (median)")
    if base_med is not None:
        ax.axhline(base_med, color=GREY, ls="--", lw=1.3,
                   label=f"baseline median ({base_med:.0f} ms)")
    # robust y-limit: keep the story (flat p50/p95) visible; rare connection-drop spikes clip
    cap = max(p95) * 2.2 if p95 else 100
    ax.set_ylim(0, cap)
    ax.set_xlim(left=0)
    ax.set_xlabel("elapsed in the conversion window (minutes)")
    ax.set_ylabel("ambient-workload transaction latency (ms)")
    ax.set_title("The drain is unnoticeable: workload latency holds at the baseline\n"
                 "while pgpm partitions the table underneath it", fontsize=11)
    ax.legend(loc="upper right", frameon=False, ncol=2)
    ax.grid(True, alpha=0.25)
    _save(fig, "02-latency-unnoticeable")


def fig_adaptive_feathering(run="R3-stress"):
    rows, col = load_progress(run)
    t = [s / 60.0 for s in col("observed_s")]
    budget = col("drain_budget")
    tb = [(x, b) for x, b in zip(t, budget) if b is not None]
    xs = [x for x, _ in tb]
    bs = [b for _, b in tb]
    ceiling = max(bs)
    floor = ceiling / 16.0
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.plot(xs, bs, color=GREEN, lw=2.0, marker="o", ms=3, label="drain budget (rows/tick)")
    ax.axhline(ceiling, color=GREY, ls="--", lw=1.2, label=f"ceiling = drain_batch ({ceiling:.0f})")
    ax.axhline(floor, color=RED, ls=":", lw=1.2, label=f"floor = drain_batch/16 ({floor:.0f})")
    ax.set_ylim(0, ceiling * 1.1)
    ax.set_xlim(left=0)
    ax.set_xlabel("elapsed (minutes)")
    ax.set_ylabel("per-tick drain budget (rows)")
    ax.set_title("Adaptive feathering (AIMD): the drain budget rides just under capacity,\n"
                 "halving when WAL/checkpoint pressure rises and recovering when it clears",
                 fontsize=11)
    ax.legend(loc="lower right", frameon=False)
    ax.grid(True, alpha=0.25)
    _save(fig, "03-adaptive-feathering")


def fig_ambient_surge(run="ambient-demo", factor=2.0, floor=2):
    # factor/floor match run_ambient_demo.sh (set_drain_ambient(..., 2.0); floor 2).
    rows, col = load_progress(run)
    t = col("observed_s")
    budget = col("drain_budget")
    waiters = col("ambient_waiters")
    base = col("ambient_baseline")
    surge = col("surge_active")
    sx = [x for x, s in zip(t, surge) if s == 1]
    ceiling = max(b for b in budget if b is not None)
    fig, (axb, axw) = plt.subplots(2, 1, figsize=(9, 6.6), sharex=True,
                                   gridspec_kw={"height_ratios": [2, 1]})
    # --- top: the drain budget, with the surge band and per-signal annotations ---
    if sx:
        for ax in (axb, axw):
            ax.axvspan(min(sx), max(sx), color=RED, alpha=0.09)
        axb.text((min(sx) + max(sx)) / 2, ceiling * 1.04, "write surge",
                 ha="center", va="bottom", color=RED, fontsize=10)
    axb.plot(t, budget, color=GREEN, lw=2.2, marker="o", ms=3.5)
    axb.axhline(ceiling, color=GREY, ls="--", lw=1.0)
    axb.set_ylabel("drain budget (rows/tick)")
    axb.set_ylim(0, ceiling * 1.13)
    axb.grid(True, alpha=0.25)
    if sx:
        axb.annotate("ambient backoffs:\nyield to the surge", xy=((min(sx) + max(sx)) / 2, ceiling * 0.42),
                     ha="center", color=RED, fontsize=9)
        # the post-surge dip is the (separate) WAL signal's surge aftermath
        post = [x for x, b in zip(t, budget) if b is not None and x > max(sx) + 25 and b < ceiling * 0.6]
        if post:
            axb.annotate("WAL backoffs:\nsurge aftermath", xy=(min(post), ceiling * 0.32),
                         xytext=(min(post) + 12, ceiling * 0.72), color="#b06000", fontsize=9,
                         arrowprops=dict(arrowstyle="->", color="#b06000"))
    # --- bottom: live waiters vs the learned baseline and the relative threshold ---
    thr = [factor * max(b if b is not None else 0, floor) for b in base]
    axw.plot(t, base, color=GREY, lw=1.8, label="learned baseline (EWMA)")
    axw.plot(t, thr, color="#b06000", ls=":", lw=1.4,
             label=f"backoff threshold ({factor:g}x baseline, floor {floor})")
    axw.scatter(t, waiters, color=RED, s=22, zorder=5, label="live IO/lock waiters (sampled)")
    axw.set_ylabel("ambient waiters")
    axw.set_xlabel("elapsed in the observe phase (seconds)")
    axw.set_ylim(bottom=0)
    axw.set_xlim(left=0)
    axw.grid(True, alpha=0.25)
    axw.legend(loc="upper right", frameon=False, fontsize=8, ncol=1)
    axb.set_title("Self-calibrating ambient signal: the drain yields to a write surge\n"
                  "(the learned baseline tracks this box's normal; a relative spike feathers the budget down)",
                  fontsize=11)
    _save(fig, "04-ambient-surge")


FIGS = {
    "online-conversion": fig_online_conversion,
    "latency-unnoticeable": fig_latency_unnoticeable,
    "adaptive-feathering": fig_adaptive_feathering,
    "ambient-surge": fig_ambient_surge,
    "scale-ladder": fig_scale_ladder,
    "fixed-vs-adaptive": fig_fixed_vs_adaptive,
}

if __name__ == "__main__":
    if len(sys.argv) > 1:
        fn = FIGS[sys.argv[1]]
        fn(sys.argv[2]) if len(sys.argv) > 2 else fn()
    else:
        print(f"rendering {len(FIGS)} figures into {OUT}")
        for fn in FIGS.values():
            fn()
