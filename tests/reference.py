# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
# distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/
# Origin of the maths: UT Bot idea by Yo_adriiiiaan (from an original idea by HPotter), TradingView "UT Bot Alerts" by
# QuantNomad; Supertrend is the textbook ATR-band indicator.
"""Python statement of the Gold Trend Sentinel rule, on bars you supply (no terminal needed).

Signals (on each closed H4 bar, from its own and earlier bars only):
    UT Bot line (key 1.5, ATR 10, on the close), Supertrend(10, 3) on the bar's (high + low) / 2, and the last completed
    daily close against its EMA(200) (seeded with the SMA of the first 200 daily closes).
    buy  = close crosses above the UT Bot line AND Supertrend is up AND the daily close is above its EMA
    sell = the mirror
Trade handling (the EA's): market order at the next bar's open (buy at the ask, sell at the bid); stop 3 x ATR(14) from the
fill; the stop then trails 3 x ATR(14) (the entry distance) behind the best price since the start of the entry bar, tightened
once per bar and never loosened, and if the new stop is already through the open price the trade closes at that open. No
target. An opposite signal reverses at the open; a same-side signal is ignored (the trail is still tightened). ATRs are
Wilder's (RMA), seeded with the SMA of the first values. Stops are tested on the bar extremes: a buy on the bid low, a sell on
the ask high (bid + spread); a gap fills at the open."""
import numpy as np
import pandas as pd

NAN = np.nan


def true_range(h, l, c):
    tr = h - l
    tr[1:] = np.maximum(tr[1:], np.maximum(np.abs(h[1:] - c[:-1]), np.abs(l[1:] - c[:-1])))
    return tr


def rma(x, n):
    out = np.full(len(x), NAN)
    if len(x) < n:
        return out
    out[n - 1] = x[:n].mean()
    for i in range(n, len(x)):
        out[i] = (out[i - 1] * (n - 1) + x[i]) / n
    return out


def ut_line(c, atr, key):
    stop = np.full(len(c), NAN)
    for i in range(len(c)):
        if np.isnan(atr[i]):
            stop[i] = stop[i - 1] if i > 0 else NAN
            continue
        prev = stop[i - 1] if i > 0 and not np.isnan(stop[i - 1]) else 0.0
        s, s1, nl = c[i], (c[i - 1] if i > 0 else c[i]), key * atr[i]
        if s > prev and s1 > prev:
            stop[i] = max(prev, s - nl)
        elif s < prev and s1 < prev:
            stop[i] = min(prev, s + nl)
        else:
            stop[i] = s - nl if s > prev else s + nl
    return stop


def supertrend_dir(h, l, c, atr, mult):
    """+1 up, -1 down, 0 before the ATR exists."""
    d_out = np.zeros(len(c), int)
    up = dn = st = 0.0
    have = False
    for i in range(len(c)):
        if np.isnan(atr[i]):
            continue
        src = (h[i] + l[i]) / 2.0
        ub, lb = src + mult * atr[i], src - mult * atr[i]
        if have:
            lb = lb if (lb > dn or c[i - 1] < dn) else dn
            ub = ub if (ub < up or c[i - 1] > up) else up
        if not have:
            d = 1.0
        elif st == up:
            d = -1.0 if c[i] > ub else 1.0
        else:
            d = 1.0 if c[i] < lb else -1.0
        up, dn = ub, lb
        st = lb if d < 0 else ub
        have = True
        d_out[i] = 1 if d < 0 else -1
    return d_out


def daily_ema_dir(d_close, period=200):
    """Per daily bar: +1 if its close is above the EMA of the closes up to and including it, -1 below, 0 before it exists."""
    out = np.zeros(len(d_close), int)
    if len(d_close) < period:
        return out
    e = d_close[:period].mean()
    k = 2.0 / (period + 1)
    out[period - 1] = 1 if d_close[period - 1] > e else (-1 if d_close[period - 1] < e else 0)
    for i in range(period, len(d_close)):
        e += k * (d_close[i] - e)
        out[i] = 1 if d_close[i] > e else (-1 if d_close[i] < e else 0)
    return out


def signals(h4: pd.DataFrame, d1: pd.DataFrame, key=1.5, ut_atr=10, st_atr=10, st_mult=3.0, ema=200):
    """h4, d1: DataFrames indexed by bar open time (server time) with open, high, low, close. Returns a Series of +1/-1/0 per
    H4 bar (the signal known when that bar has closed) and the ATR(14) used for the stop."""
    o, h, l, c = (h4[k].to_numpy(float) for k in ("open", "high", "low", "close"))
    tr = true_range(h, l, c)
    ut = ut_line(c, rma(tr, ut_atr), key)
    st = supertrend_dir(h, l, c, rma(tr, st_atr), st_mult)
    atr14 = rma(tr, 14)
    ddir = daily_ema_dir(d1.close.to_numpy(float), ema)
    d_end = d1.index + pd.Timedelta(days=1)                       # a daily bar is complete at the next day's open
    h4_end = h4.index + (h4.index[1] - h4.index[0])
    pos = np.searchsorted(d_end.values, h4_end.values, side="right") - 1   # last daily bar completed by the H4 close
    sig = np.zeros(len(c), int)
    for j in range(1, len(c)):
        if np.isnan(ut[j]) or np.isnan(ut[j - 1]) or np.isnan(atr14[j]) or pos[j] < 0:
            continue
        dd = ddir[pos[j]]
        if c[j] > ut[j] and c[j - 1] <= ut[j - 1] and dd > 0 and st[j] > 0:
            sig[j] = 1
        elif c[j] < ut[j] and c[j - 1] >= ut[j - 1] and dd < 0 and st[j] < 0:
            sig[j] = -1
    return pd.Series(sig, index=h4.index), pd.Series(atr14, index=h4.index)


def run(h4: pd.DataFrame, d1: pd.DataFrame, spread: pd.Series, stop_mult=3.0, **kw) -> pd.DataFrame:
    """Trades (gross of swap). h4 holds bid open/high/low/close; `spread` is per H4 bar in price units (ask = bid + spread)."""
    sig, atr = signals(h4, d1, **kw)
    sig = sig.to_numpy()
    bo, bh, bl = (h4[k].to_numpy(float) for k in ("open", "high", "low"))
    sp = spread.to_numpy(float)
    ao, ah, al = bo + sp, bh + sp, bl + sp
    n, trades = len(h4), []
    pos, fill, sl, dist, k_in = 0, 0.0, 0.0, 0.0, 0

    def close(k, px, why):
        nonlocal pos
        pnl = pos * (px - fill)
        trades.append(dict(entry_time=h4.index[k_in], exit_time=h4.index[k], dir=pos, entry=fill, exit=px, pnl=pnl,
                           r=pnl / dist, dist=dist, why=why))
        pos = 0

    def trail(k):
        nonlocal sl
        if pos == 0 or k_in >= k:
            return
        best = max(fill, bh[k_in:k].max()) if pos > 0 else min(fill, al[k_in:k].min())
        ns = best - dist if pos > 0 else best + dist
        if (pos > 0 and ns <= sl) or (pos < 0 and ns >= sl):
            return
        if (pos > 0 and ns >= bo[k]) or (pos < 0 and ns <= ao[k]):
            close(k, bo[k] if pos > 0 else ao[k], "trail through the price")
            return
        sl = ns

    for k in range(1, n):
        # the stop is tested inside the previous bar (k-1) with the stop in force during it
        if pos != 0 and k - 1 >= k_in:
            j = k - 1
            if pos > 0 and bl[j] <= sl:
                close(j, min(sl, bo[j]), "stop")
            elif pos < 0 and ah[j] >= sl:
                close(j, max(sl, ao[j]), "stop")
        s = sig[k - 1]                  # the bar that just closed decides; the order goes out at bar k's open
        if s != 0:
            if pos == s:
                trail(k)
            else:
                if pos == -s:
                    close(k, bo[k] if pos > 0 else ao[k], "reversed")
                if pos == 0 and not np.isnan(atr.iloc[k - 1]):
                    fill = ao[k] if s > 0 else bo[k]
                    dist = stop_mult * atr.iloc[k - 1]
                    sl = fill - dist if s > 0 else fill + dist
                    pos, k_in = s, k
        else:
            trail(k)
    return pd.DataFrame(trades)
