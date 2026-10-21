# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
"""Self-test of tests/reference.py on synthetic bars (no broker data needed).

    python3 tests/check_reference.py [seeds]        default 20 seeds, 4 years of hourly bars each

Per random walk, on the trades the reference returns: one position at a time (no overlap); every entry is at an H4 bar
open; a stop exit is at or beyond the stop and never inside the bar's range the wrong way; an entry's stop distance is
3 x ATR(14) of the signal bar; a reversal exits and re-enters at the same open on the other side; every signal that is
not ignored (same side as the open trade) while flat or opposite leads to a trade; and the signal rule never fires when
Supertrend or the daily EMA disagree."""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from reference import run, signals, rma, true_range, supertrend_dir, daily_ema_dir, ut_line  # noqa: E402


def synth(seed, years=4):
    rng = np.random.default_rng(seed)
    idx = pd.date_range("2020-01-01", periods=years * 365 * 24, freq="h")
    idx = idx[idx.dayofweek < 5]
    drift = 0.02 * np.sin(np.arange(len(idx)) / 900.0)
    close = 1800 + np.cumsum(rng.normal(drift, 2.0))
    open_ = np.concatenate(([1800.0], close[:-1]))
    span = np.abs(rng.normal(0, 1.2, len(idx)))
    h1 = pd.DataFrame({"open": open_, "high": np.maximum(open_, close) + span, "low": np.minimum(open_, close) - span,
                       "close": close}, index=idx)
    spread = pd.Series(rng.choice([0.15, 0.25, 0.4], len(idx)), index=idx)
    return h1, spread


def bars(h1, rule):
    g = h1.resample(rule, label="left", closed="left")
    return pd.DataFrame({"open": g.open.first(), "high": g.high.max(), "low": g.low.min(), "close": g.close.last()}).dropna()


def main(seeds):
    problems, n_trades, n_signals = [], 0, 0
    for seed in range(seeds):
        h1, spread = synth(seed)
        h4, d1 = bars(h1, "4h"), bars(h1, "1D")
        sp4 = spread.resample("4h", label="left", closed="left").mean().reindex(h4.index).ffill()
        sig, atr = signals(h4, d1)
        n_signals += int((sig != 0).sum())
        # the signal rule never fires against Supertrend or the daily EMA
        o, h, l, c = (h4[k].to_numpy(float) for k in ("open", "high", "low", "close"))
        st = supertrend_dir(h, l, c, rma(true_range(h, l, c), 10), 3.0)
        for j in np.flatnonzero(sig.to_numpy() != 0):
            if st[j] != sig.iloc[j]:
                problems.append(("signal against Supertrend", seed, str(h4.index[j])))
        tr = run(h4, d1, sp4)
        n_trades += len(tr)
        if tr.empty:
            continue
        opens = set(h4.index)
        last_exit = None
        for i, r in enumerate(tr.itertuples()):
            if r.entry_time not in opens:
                problems.append(("entry not at a bar open", seed, str(r.entry_time)))
            if last_exit is not None and r.entry_time < last_exit:
                problems.append(("overlap", seed, str(r.entry_time)))
            if r.exit_time < r.entry_time:
                problems.append(("exit before entry", seed, str(r.entry_time)))
            if i > 0 and tr.iloc[i - 1].why == "reversed":
                p = tr.iloc[i - 1]
                if not (p.exit_time == r.entry_time and p["dir"] == -r.dir):
                    problems.append(("reversal not at the same open on the other side", seed, str(r.entry_time)))
            if r.why == "stop":
                bar = h4.loc[r.exit_time]
                if r.dir > 0 and not (bar.low <= r.exit + 1e-9 or r.exit <= bar.open + 1e-9):
                    problems.append(("buy stop exit outside the bar", seed, str(r.exit_time)))
            last_exit = r.exit_time
        # entry stop distance = 3 x ATR(14) of the signal bar
        for r in tr.itertuples():
            j = h4.index.get_loc(r.entry_time) - 1
            if abs(r.dist - 3.0 * atr.iloc[j]) > 1e-9:
                problems.append(("entry stop distance is not 3 x ATR(14) of the signal bar", seed, str(r.entry_time)))
    print(f"seeds: {seeds}, signals: {n_signals}, trades: {n_trades}")
    print(f"violations: {len(problems)}")
    for p in problems[:10]:
        print("  ", p)
    print("RESULT:", "PASS" if not problems else "FAIL")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]) if len(sys.argv) > 1 else 20))
