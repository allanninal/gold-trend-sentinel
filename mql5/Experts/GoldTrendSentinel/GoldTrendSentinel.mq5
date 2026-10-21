//+------------------------------------------------------------------+
//|                                            GoldTrendSentinel.mq5 |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| FREE edition: always 0.01 lot (or the broker's minimum when it   |
//| is larger). The strategy and everything else is the shared core. |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
#property copyright "Copyright 2026, Allan Niñal <https://www.allanninal.dev/mql5>"
#property link      "https://www.allanninal.dev/mql5"
#property version   "1.10"
#property icon      "GoldTrendSentinel.ico"
#property description "Gold H4 trend follower: UT Bot entries with daily and Supertrend filters, and a 3 x ATR trailing stop."
#property description "FREE edition: fixed 0.01 lot."

#define GTS_VERSION "1.10"                  // keep equal to #property version
#include "GoldTrendSentinel.mqh"
//+------------------------------------------------------------------+
