# Publish gate for the MetaTrader 4 edition (criteria written before any number was computed)

Setting (frozen, nothing re-optimised): XAUUSD H4, UT Bot key 1.5 / ATR 10, daily close above or below its EMA(200),
Supertrend(10, 3) agrees; market order at the next H4 open, stop and chandelier trail 3 x ATR(14), reverse on an opposite
signal. Period: entries 2023-07-01 to 2026-09-30, halves split at 2025-02-15. Results in R (R = the initial stop distance of
each trade), spread and swap included, no commission.

Criteria (all must hold): 1. at least 40 trades; 2. mean R > 0 and t >= 2.0; 3. profit factor >= 1.20; 4. mean R > 0 and profit
factor > 1 in both halves.

| Run | Trades | mean R | t | PF | first half R (PF) | second half R (PF) | criteria 1-4 |
|---|---:|---:|---:|---:|---|---|---|
| Python simulation | 58 | 0.447 | 2.65 | 3.01 | 0.595 (4.53), 26 trades | 0.326 (2.23), 32 trades | pass |
| MetaTrader 4 Strategy Tester, every tick | 57 | 0.433 | 2.53 | 2.86 | 0.552 | 0.333 | pass |

MT4 tester run: two spread chunks (a fixed 170 points to September 2025, 20 points after), because the MT4 tester charges one
fixed spread per run. Signals identical: 74 of 74. Entries matched with the Python list 98.3 %, exits 98.2 %. The one Python trade
the MT4 run lacks opened on the last day of the test and was cut by its end.

This is one test of one pre-existing setting (no search), so no multiple-testing correction applies; a pass means "not rejected".

# Checks recorded for the MetaTrader 5 edition (scripts that need the author's private research environment; not published)

| Check | Result |
|---|---|
| Signals of the EA's indicator code against the research rule, Oct 2021 to Oct 2026 | 112 of 112 identical |
| Trades of the EA's trade handling against the research engine (version 1.01) | 85 of 85 identical |
| H4 (18,157) and D1 (3,033) candles rebuilt on other broker clocks (version 1.04) | all identical to the New York-close candles |
