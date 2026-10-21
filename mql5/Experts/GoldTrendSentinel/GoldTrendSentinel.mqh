//+------------------------------------------------------------------+
//|                                            GoldTrendSentinel.mqh |
//|                                      Copyright 2026, Allan Niñal |
//|                                  https://www.allanninal.dev/mql5 |
//+------------------------------------------------------------------+
//| Gold Trend Sentinel: a gold H4 trend follower.                      |
//|   On each new H4 bar, from the last closed one:                  |
//|   buy  when the close crosses above the UT Bot stop line         |
//|        (key 1.5, ATR 10) AND the last completed daily close is   |
//|        above its EMA(200) AND Supertrend(10, 3) on H4 is up;     |
//|   sell is the mirror. Market order at the bar's open; stop       |
//|   3 x ATR(14) from the fill, then a chandelier trail 3 x ATR     |
//|   behind the best price since entry, tightened once per H4 bar.  |
//|   No target. An opposite signal reverses; a same-side signal     |
//|   while in a trade is ignored. ATRs are Wilder's (RMA) seeded    |
//|   with an SMA, as TradingView computes them.                     |
//| Candles: the rule was researched on New York-close candles       |
//|   (server time UTC+2, or UTC+3 while US daylight saving is on).  |
//|   On a broker with another server clock, H4 and D1 candles are   |
//|   rebuilt from H1 on that clock, so the signals stay the same.   |
//| Lot: always 0.01, or the broker's minimum when that is larger;   |
//|   no lot inputs. No network calls.                               |
//|   Every order is checked for margin and for surviving its stop   |
//|   above the broker's stop-out level. Live and demo charts trade  |
//|   XAUUSD only; the Strategy Tester may test any symbol.          |
//+------------------------------------------------------------------+
// SPDX-License-Identifier: MPL-2.0
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
// distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/
// Origin of the maths: UT Bot idea by Yo_adriiiiaan (from an original idea by HPotter), TradingView "UT Bot Alerts" by
// QuantNomad; Supertrend is the textbook ATR-band indicator.

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
//--- Inputs-dialog text. MT5 shows each enum choice by the comment on its own line, so every member,
//--- including the last, needs its comment before the closing brace.
enum ENUM_GTS_CORNER
  {
   GTS_LEFT=0,      // Top left
   GTS_RIGHT=1      // Top right
  };

enum ENUM_GTS_CLOCK
  {
   GTS_CLOCK_AUTO=0,    // Auto: detect from the live server time
   GTS_CLOCK_NY=1,      // New York close: UTC+2/+3 with US daylight saving
   GTS_CLOCK_EET=2,     // UTC+2/+3 with European daylight saving
   GTS_CLOCK_FIXED=3    // Fixed offset from UTC (set below), no daylight saving
  };

input group "STRATEGY (defaults = the tested rule)"
input int             InpMagic     = 770100;     // Magic number (order ID)
input ENUM_TIMEFRAMES InpTF        = PERIOD_H4;  // Signal timeframe
input double          InpUTKey     = 1.5;        // UT Bot key value
input int             InpUTATR     = 10;         // UT Bot ATR period
input int             InpSTPeriod  = 10;         // Supertrend ATR period
input double          InpSTMult    = 3.0;        // Supertrend multiplier
input int             InpTrendEMA  = 200;        // Daily trend EMA period
input int             InpStopATR   = 14;         // Stop ATR period
input double          InpStopMult  = 3.0;        // Stop and trail, x ATR
input bool            InpTrail     = true;       // Trail the stop

input group "CANDLE CLOCK (the rule uses New York-close candles)"
input ENUM_GTS_CLOCK  InpClock     = GTS_CLOCK_AUTO; // Broker server clock
input int             InpFixedUTC  = 0;          // Broker offset from UTC, hours (Fixed offset only)

input group "DISPLAY"
input bool            InpShowPanel   = true;      // Show info panel
input bool            InpShowLevels  = true;      // Show the UT Bot line and signals
input bool            InpLightTheme  = false;     // Light colours (for white charts)
input ENUM_GTS_CORNER InpCorner      = GTS_LEFT;  // Panel position
input int             InpOffsetX     = 10;        // Panel margin from the side, px
input int             InpOffsetY     = 26;        // Panel margin from the top, px
input int             InpFontSize    = 9;         // Panel font size

input group "SUPPORT"
input bool            InpDebug       = false;     // Debug log for bug reports (Experts tab)

//+------------------------------------------------------------------+
//| Constants and state                                              |
//+------------------------------------------------------------------+
#define WIN      1500                  // signal-timeframe bars the indicators are rebuilt over
#define D1WIN    1500                  // daily bars for the EMA(200)
#define MIN_BARS 300                   // signal bars required before trading
#define PREFIX   "GTS_"                // chart object prefix
#define MARKERS  60                    // signal markers kept on the chart
#define GAP_MULT 2.0                   // plan for twice the loss at the stop: a gap, or a tester that only
                                       // checks stops at bar opens, can carry the price past it

datetime g_last_bar = 0;               // open time of the last processed signal bar

//--- symbol properties cached in OnInit
double   g_tick=0, g_vol_min=0, g_vol_max=0, g_vol_step=0;
bool     g_fok=false, g_gtc=true;

//--- status
bool     g_symbol_ok=true;             // XAUUSD on live charts (any symbol in the tester)

//--- what the last evaluation saw, for the panel and the trail
double   g_ut_stop=0;                  // UT Bot line on the last closed bar
int      g_ut_side=0;                  // +1 close above the line, -1 below
int      g_st_dir=0;                   // Supertrend +1 up / -1 down
int      g_d1_dir=0;                   // daily close vs EMA: +1 above / -1 below
double   g_d1_close=0, g_d1_ema=0;
double   g_atr_stop=0;                 // ATR(14) on the last closed bar
double   g_pdh=0;                      // reference price for the Risk row (current bid)
double   g_ref_stop=0;                 // stop distance the next trade would use
datetime g_sig_time=0;                 // bar of the last buy/sell signal
int      g_sig_side=0;                 // +1 buy, -1 sell
string   g_sig_result="";              // "placed" / "reversed" / why it was skipped
bool     g_market_open=true;
//--- candle clock
bool     g_native=true;                // the broker already runs on New York-close time: use its own candles
ENUM_GTS_CLOCK g_clock=GTS_CLOCK_NY;   // resolved clock (Auto becomes one of the others)
int      g_fixed_off=0;                // seconds, for GTS_CLOCK_FIXED

//--- panel state
bool     g_ui=false, g_collapsed=false, g_stats_dirty=true;
int      g_rows=0;
string   g_cache_txt[];
int      g_cache_x[], g_cache_y[], g_cache_w[], g_cache_h[];   // last geometry sent per object
color    g_cache_fill[];
int      g_cursor=0;                   // the panel draws in the same order every time: try this slot first
bool     g_panel_dirty=true;           // something changed since the last ChartRedraw
datetime g_cache_reset=0;              // the cache is dropped once a minute, so deleted objects come back
color    g_cache_clr[];
string   g_cache_name[];
int      g_closed=0, g_wins=0;
ulong    g_last_deal=0;                // closed-trade results are read incrementally: highest deal counted
datetime g_hist_from=0;                // history is loaded from here on the next update
datetime g_today_start=0;
long     g_open_ids[];                 // positions of this EA with deals but not yet closed
double   g_open_pnl[];
double   g_net=0, g_gross_win=0, g_gross_loss=0, g_today=0;
double   g_curve=0, g_curve_peak=0, g_max_dd=0;   // closed-trade results in sequence, for the worst drawdown
int      g_mon_key[];                             // yyyymm of the months with closed trades
double   g_mon_net[];                             // their results
int      g_markers=0;
datetime g_last_ui=0;

//+------------------------------------------------------------------+
//| Palette (same as Vitals)                                         |
//+------------------------------------------------------------------+
color UiBack()       { return(InpLightTheme ? C'250,250,251' : C'24,26,30');    }  // panel background
color UiText()       { return(InpLightTheme ? C'44,48,56'    : C'206,212,220'); }  // values
color UiLabel()      { return(InpLightTheme ? C'124,131,142' : C'122,130,142'); }  // field names
color UiHead()       { return(InpLightTheme ? C'92,100,112'  : C'150,160,175'); }  // section titles
color UiDim()        { return(InpLightTheme ? C'140,146,157' : C'96,102,112');  }  // zero / no data
color UiPos()        { return(InpLightTheme ? C'38,118,66'   : C'126,192,143'); }  // sage, not Lime
color UiNeg()        { return(InpLightTheme ? C'176,58,58'   : C'226,124,124'); }  // coral, not Red
color UiWarn()       { return(InpLightTheme ? C'160,112,28'  : C'220,178,116'); }  // amber
color UiAccent()     { return(InpLightTheme ? C'48,92,148'   : C'132,164,206'); }  // market data
color UiRule()       { return(InpLightTheme ? C'220,223,228' : C'48,52,58');    }  // group divider

//+------------------------------------------------------------------+
//| Panel geometry, px at font size 9                                |
//+------------------------------------------------------------------+
#define UI_W        306                // panel width (27 characters of value)
#define UI_PAD      10                 // inner padding
#define UI_VAL      106                // value column (clears "Profit factor" at font 9)
#define UI_ROW      16                 // row height
#define UI_HEAD     24                 // title bar height
#define UI_GAP      6                  // space above a section title
#define UI_CHAR     7                  // Consolas 9 advance width, px

//+------------------------------------------------------------------+
//| Rounds a price to the symbol tick size                           |
//+------------------------------------------------------------------+
double FixPrice(const double price)
  {
   if(g_tick==0)
      return(NormalizeDouble(price,_Digits));
   return(NormalizeDouble(MathRound(price/g_tick)*g_tick,_Digits));
  }

//+------------------------------------------------------------------+
//| True inside a trading session of the chart symbol, server time   |
//+------------------------------------------------------------------+
bool IsMarketOpen(void)
  {
   datetime now=TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(now,dt);
   int      tod=(int)(now%86400);
   datetime from,to;
   for(int s=0; SymbolInfoSessionTrade(_Symbol,(ENUM_DAY_OF_WEEK)dt.day_of_week,s,from,to); s++)
     {
      int f=(int)(from%86400),t=(int)(to%86400);
      if(f<t ? (tod>=f && tod<t) : (tod>=f || tod<t))   // the session end itself is closed (orders rejected)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Sends a request and reports whether the server accepted it       |
//+------------------------------------------------------------------+
bool Send(MqlTradeRequest &request)
  {
   MqlTradeResult result;
   ZeroMemory(result);
   return(OrderSend(request,result) &&
          (result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_PLACED));
  }

//+------------------------------------------------------------------+
//| True for an order or position of this EA on this symbol          |
//+------------------------------------------------------------------+
bool MyPosition(const ulong ticket)
  {
   return(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC)==InpMagic &&
          PositionGetString(POSITION_SYMBOL)==_Symbol);
  }

//+------------------------------------------------------------------+
//| Risk shown on the panel: the percent of balance lost at the stop,|
//| and its name. Bands: Safe <= 1, Medium <= 2, High <= 3, Very high|
//| <= 5, Extreme above.                                             |
//+------------------------------------------------------------------+

string RiskName(const double pct)
  {
   if(pct<=1.0) return("Safe");
   if(pct<=2.0) return("Medium");
   if(pct<=3.0) return("High");
   if(pct<=5.0) return("Very high");
   return("Extreme");
  }

color RiskColor(const double pct)
  {
   if(pct<=1.0) return(UiPos());
   if(pct<=2.0) return(UiAccent());
   if(pct<=3.0) return(UiWarn());
   return(UiNeg());
  }

//--- money lost at the stop by one lot
double LossPerLot(const double price,const double sl)
  {
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv<=0)
      tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double by_tick=(g_tick>0 ? MathAbs(price-sl)/g_tick : 0)*tv;
   //--- the terminal's own profit maths (contract size, currency conversion); tick values can be stale or
   //--- quoted for another lot in some accounts, so the larger of the two is used
   double p=0;
   if(price!=sl && OrderCalcProfit(sl<price ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,1.0,price,sl,p))
      return(MathMax(by_tick,MathAbs(p)));
   return(by_tick);
  }

//+------------------------------------------------------------------+
//| The minimum lot: 0.01, or the broker's minimum on  |
//| this symbol when that is larger (0.10 at some brokers). A broker |
//| that allows less than 0.01 still gets 0.01.                      |
//+------------------------------------------------------------------+
double MinLot(void)
  {
   double v=MathMax(0.01,g_vol_min);
   if(g_vol_step>0)                                  // keep it on the broker's lot step
      v=MathCeil(v/g_vol_step-1e-9)*g_vol_step;
   return(NormalizeDouble(v,8));
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Lot for an order at `price` with stop `sl`: always the broker's  |
//| minimum lot (SYMBOL_VOLUME_MIN: 0.01 on most brokers, 0.10 on    |
//| some), whatever the balance.                                     |
//+------------------------------------------------------------------+
double TradeVolume(const double price,const double sl,string &why)
  {
   return(MinLot());                                 // FREE: 0.01 or the broker minimum, whatever the balance
  }

//+------------------------------------------------------------------+
//| "" when the account can take a new position of `volume` at       |
//| `price` with stop `sl`; otherwise the reason. Two conditions:    |
//| the margin fits in free margin, and if every open position of    |
//| this EA and the new one all reach their stops, equity stays above|
//| the broker's stop-out level for the margin then in use. A broker |
//| would reject the first and force-close the second.               |
//+------------------------------------------------------------------+
string Affordable(const bool buy,const double volume,const double price,const double sl)
  {
   double margin=0;
   if(!OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,volume,price,margin) ||
      margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      return("not enough margin");
   double worst=AccountInfoDouble(ACCOUNT_EQUITY)-GAP_MULT*volume*LossPerLot(price,sl);
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      if(!MyPosition(PositionGetTicket(i)))
         continue;
      double psl=PositionGetDouble(POSITION_SL);
      double cur=PositionGetDouble(POSITION_PRICE_CURRENT);
      bool   pbuy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
      if(psl>0 && (pbuy ? psl<cur : psl>cur))          // room left between the price now and its stop
         worst-=GAP_MULT*PositionGetDouble(POSITION_VOLUME)*LossPerLot(cur,psl);
     }
   double so=AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
   double used=AccountInfoDouble(ACCOUNT_MARGIN)+margin;
   double floor_=AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE)==ACCOUNT_STOPOUT_MODE_PERCENT ? used*so/100.0 : so;
   if(worst<=floor_)
      return("balance too small for SL");
   return("");
  }

//+------------------------------------------------------------------+
//| Chart objects: one cached setter so unchanged text is not resent |
//+------------------------------------------------------------------+
int CacheSlot(const string name)
  {
   int n=ArraySize(g_cache_name);
   if(g_cursor<n && g_cache_name[g_cursor]==name)
      return(g_cursor++);
   for(int i=0; i<n; i++)
      if(g_cache_name[i]==name)
        {
         g_cursor=i+1;
         return(i);
        }
   ArrayResize(g_cache_name,n+1);
   ArrayResize(g_cache_txt,n+1);
   ArrayResize(g_cache_clr,n+1);
   ArrayResize(g_cache_x,n+1);
   ArrayResize(g_cache_y,n+1);
   ArrayResize(g_cache_w,n+1);
   ArrayResize(g_cache_h,n+1);
   ArrayResize(g_cache_fill,n+1);
   g_cache_name[n]=name;
   g_cache_txt[n]="\x01";
   g_cache_clr[n]=clrNONE;
   g_cache_fill[n]=clrNONE;
   g_cache_x[n]=g_cache_y[n]=g_cache_w[n]=g_cache_h[n]=INT_MIN;
   g_cursor=n+1;
   return(n);
  }

void CacheClear(void)
  {
   ArrayResize(g_cache_name,0);
   ArrayResize(g_cache_txt,0);
   ArrayResize(g_cache_clr,0);
   ArrayResize(g_cache_x,0);
   ArrayResize(g_cache_y,0);
   ArrayResize(g_cache_w,0);
   ArrayResize(g_cache_h,0);
   ArrayResize(g_cache_fill,0);
   g_cursor=0;
   g_panel_dirty=true;
  }

//--- sets an integer property only when it differs from what was last sent
void SetInt(const string name,const ENUM_OBJECT_PROPERTY_INTEGER prop,const long v,int &cache)
  {
   if(cache==(int)v)
      return;
   ObjectSetInteger(0,name,prop,v);
   cache=(int)v;
   g_panel_dirty=true;
  }

//--- x distance of a point `x` px from the panel's left edge, for either corner
int PanelX(const int x)
  {
   return(InpCorner==GTS_LEFT ? InpOffsetX+x : InpOffsetX+UI_W-x);
  }

ENUM_BASE_CORNER PanelCorner(void)
  {
   return(InpCorner==GTS_LEFT ? CORNER_LEFT_UPPER : CORNER_RIGHT_UPPER);
  }

void Text(const string id,const int x,const int y,const string text,const color clr,
          const int size=0,const string font="Consolas")
  {
   string name=PREFIX+id;
   string txt=(text=="") ? " " : text;           // an empty label would show the word "Label"
   int slot=CacheSlot(name);
   if(g_cache_x[slot]==INT_MIN && ObjectFind(0,name)<0)    // first time this object is seen
     {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,PanelCorner());
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetString(0,name,OBJPROP_FONT,font);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size>0 ? size : InpFontSize);
     }
   SetInt(name,OBJPROP_XDISTANCE,PanelX(x),g_cache_x[slot]);
   SetInt(name,OBJPROP_YDISTANCE,InpOffsetY+y,g_cache_y[slot]);
   if(g_cache_txt[slot]!=txt)
     {
      ObjectSetString(0,name,OBJPROP_TEXT,txt);
      g_cache_txt[slot]=txt;
      g_panel_dirty=true;
     }
   if(g_cache_clr[slot]!=clr)
     {
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      g_cache_clr[slot]=clr;
      g_panel_dirty=true;
     }
  }

void Box(const string id,const int x,const int y,const int w,const int h,const color fill,const color border)
  {
   string name=PREFIX+id;
   int slot=CacheSlot(name);
   if(g_cache_x[slot]==INT_MIN && ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,PanelCorner());
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
     }
//--- a rectangle label is anchored at its top-left corner, so on the right corner shift it by its width
   SetInt(name,OBJPROP_XDISTANCE,InpCorner==GTS_LEFT ? InpOffsetX+x : InpOffsetX+UI_W-x,g_cache_x[slot]);
   SetInt(name,OBJPROP_YDISTANCE,InpOffsetY+y,g_cache_y[slot]);
   SetInt(name,OBJPROP_XSIZE,w,g_cache_w[slot]);
   SetInt(name,OBJPROP_YSIZE,h,g_cache_h[slot]);
   if(g_cache_fill[slot]!=fill)
     {
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,fill);
      g_cache_fill[slot]=fill;
      g_panel_dirty=true;
     }
   if(g_cache_clr[slot]!=border)
     {
      ObjectSetInteger(0,name,OBJPROP_COLOR,border);
      g_cache_clr[slot]=border;
      g_panel_dirty=true;
     }
  }

void Button(const string id,const int x,const int y,const string txt)
  {
   string name=PREFIX+id;
   if(ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,PanelCorner());
      ObjectSetInteger(0,name,OBJPROP_XSIZE,18);
      ObjectSetInteger(0,name,OBJPROP_YSIZE,16);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,InpFontSize);
     }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,InpCorner==GTS_LEFT ? InpOffsetX+x : InpOffsetX+UI_W-x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,InpOffsetY+y);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,UiBack());
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,UiRule());
   ObjectSetInteger(0,name,OBJPROP_COLOR,UiHead());
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
  }

//--- one "label  value" row; returns the next y
int Row(const string id,const int y,const string label,const string value,const color clr)
  {
   int fit=(UI_W-UI_VAL-UI_PAD)/UI_CHAR;          // characters that fit in the value column
   Text(id+"_l",UI_PAD,y,label,UiLabel());
   Text(id+"_v",UI_VAL,y,StringLen(value)>fit ? StringSubstr(value,0,fit-1)+"~" : value,clr);
   return(y+UI_ROW);
  }

int Section(const string id,const int y,const string title)
  {
   int top=y+UI_GAP;
   Box(id+"_r",UI_PAD,top+UI_ROW-3,UI_W-2*UI_PAD,1,UiRule(),UiRule());
   Text(id+"_t",UI_PAD,top,title,UiHead(),InpFontSize-1);
   return(top+UI_ROW+2);
  }

//+------------------------------------------------------------------+
//| Formatting helpers                                               |
//+------------------------------------------------------------------+
string Px(const double v)     { return(v>0 ? DoubleToString(v,_Digits) : "-"); }  // 2 or 3 digit gold alike
string Money(const double v) { return((v>=0 ? "+" : "-")+DoubleToString(MathAbs(v),2)+" "+AccountInfoString(ACCOUNT_CURRENCY)); }
color  Sign(const double v)  { return(v>0 ? UiPos() : (v<0 ? UiNeg() : UiDim())); }

//--- the lot the EA uses: 0.01, or the broker minimum
string LotText(void)
  {
   return(DoubleToString(MinLot(),2)+"  fixed (FREE)");
  }

//--- percent of balance lost at the stop with the lot actually used, at yesterday's high
double g_risk_now=0;
string RiskText(void)
  {
   g_risk_now=0;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_pdh<=0 || g_ref_stop<=0 || bal<=0)
      return("-");
   string why="";
   double sl=g_pdh-g_ref_stop;
   double v=TradeVolume(g_pdh,sl,why);
   if(v<=0)
      return("-");
   g_risk_now=100.0*v*LossPerLot(g_pdh,sl)/bal;
   return(StringFormat("%.1f%% at stop  %s",g_risk_now,RiskName(g_risk_now)));
  }

string Clock(const int secs)
  {
   int s=MathMax(0,secs);
   return(s>=3600 ? StringFormat("%dh %02dm",s/3600,(s%3600)/60) : StringFormat("%02d:%02d",s/60,s%60));
  }

//+------------------------------------------------------------------+
//| Closed-trade results of this EA on this symbol, from history.    |
//| Updated only after a deal is added, and only from the last deal  |
//| already counted: the full account history is loaded once, at the |
//| first update, never again.                                       |
//+------------------------------------------------------------------+
void RecalcStats(void)
  {
   datetime today=iTime(_Symbol,PERIOD_D1,0);
   if(today!=g_today_start)                       // a new day: today's total starts again
     {
      g_today_start=today;
      g_today=0;
     }
   if(!HistorySelect(g_hist_from,TimeCurrent()+86400))
      return;
   int n=HistoryDealsTotal();
   for(int i=0; i<n; i++)
     {
      ulong d=HistoryDealGetTicket(i);
      if(d<=g_last_deal)
         continue;                                // counted on an earlier call
      g_last_deal=d;
      datetime t=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
      if(t>g_hist_from)
         g_hist_from=t;
      if(HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagic || HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol)
         continue;
      double v=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+
               HistoryDealGetDouble(d,DEAL_COMMISSION);
      long   id=HistoryDealGetInteger(d,DEAL_POSITION_ID);
      long   entry=HistoryDealGetInteger(d,DEAL_ENTRY);
      g_net+=v;
      if(t>=today)
         g_today+=v;
      int m=ArraySize(g_open_ids),j=m-1;
      while(j>=0 && g_open_ids[j]!=id)
         j--;
      if(j<0)
        {
         ArrayResize(g_open_ids,m+1);
         ArrayResize(g_open_pnl,m+1);
         j=m;
         g_open_ids[j]=id;
         g_open_pnl[j]=0;
        }
      g_open_pnl[j]+=v;
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_INOUT || entry==DEAL_ENTRY_OUT_BY)
        {
         g_closed++;
         g_curve+=g_open_pnl[j];
         g_curve_peak=MathMax(g_curve_peak,g_curve);
         g_max_dd=MathMax(g_max_dd,g_curve_peak-g_curve);
         MqlDateTime mt;
         TimeToStruct(t,mt);
         int key=mt.year*100+mt.mon,k=ArraySize(g_mon_key)-1;
         if(k<0 || g_mon_key[k]!=key)
           {
            k++;
            ArrayResize(g_mon_key,k+1);
            ArrayResize(g_mon_net,k+1);
            g_mon_key[k]=key;
            g_mon_net[k]=0;
           }
         g_mon_net[k]+=g_open_pnl[j];
         if(g_open_pnl[j]>0)
           {
            g_wins++;
            g_gross_win+=g_open_pnl[j];
           }
         else
            g_gross_loss-=g_open_pnl[j];
         m=ArraySize(g_open_ids);                 // forget the closed position: only open ones are kept
         g_open_ids[j]=g_open_ids[m-1];
         g_open_pnl[j]=g_open_pnl[m-1];
         ArrayResize(g_open_ids,m-1);
         ArrayResize(g_open_pnl,m-1);
        }
     }
   g_stats_dirty=false;
  }

//+------------------------------------------------------------------+
//| Indicators, exactly as the Python research computes them         |
//+------------------------------------------------------------------+
//--- Sunday on or after `day` of `month` in year `y`, at `hour` UTC
datetime SundayFrom(const int y,const int month,const int day,const int hour)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year=y;
   t.mon=month;
   t.day=day;
   datetime d=StructToTime(t);
   TimeToStruct(d,t);
   return(d+(datetime)(((7-t.day_of_week)%7)*86400+hour*3600));
  }

//--- US daylight saving (second Sunday of March 07:00 UTC to first Sunday of November 06:00 UTC)
bool UsDst(const datetime utc)
  {
   MqlDateTime t;
   TimeToStruct(utc,t);
   return(utc>=SundayFrom(t.year,3,8,7) && utc<SundayFrom(t.year,11,1,6));
  }

//--- EU summer time (last Sunday of March to last Sunday of October, 01:00 UTC)
bool EuDst(const datetime utc)
  {
   MqlDateTime t;
   TimeToStruct(utc,t);
   return(utc>=SundayFrom(t.year,3,25,1) && utc<SundayFrom(t.year,10,25,1));
  }

int NyOffset(const datetime utc) { return(UsDst(utc) ? 3*3600 : 2*3600); }

//--- the broker's offset from UTC at server time `srv`
int BrokerOffset(const datetime srv)
  {
   if(g_clock==GTS_CLOCK_FIXED)
      return(g_fixed_off);
   if(g_clock==GTS_CLOCK_EET)
      return(EuDst(srv-2*3600) ? 3*3600 : 2*3600);
   return(NyOffset(srv-2*3600));
  }

//--- seconds to add to server time to get New York-close time
int Shift(const datetime srv)
  {
   if(g_native)
      return(0);
   int b=BrokerOffset(srv);
   return(NyOffset(srv-b)-b);
  }

//--- open time, on the New York-close clock, of the candle of length `per` that contains server time `srv`
datetime NyBucket(const datetime srv,const int per)
  {
   long ny=(long)srv+Shift(srv);
   return((datetime)(ny-ny%per));
  }

//--- decide the clock once: the inputs, or the live server time against UTC (the tester can't tell, see OnInit)
void ResolveClock(void)
  {
   g_clock=InpClock;
   g_fixed_off=InpFixedUTC*3600;
   if(InpClock==GTS_CLOCK_AUTO)
     {
      g_clock=GTS_CLOCK_NY;
      if(!MQLInfoInteger(MQL_TESTER))
        {
         datetime gmt=TimeGMT();
         int off=(int)MathRound((double)(TimeTradeServer()-gmt)/1800.0)*1800;
         if(off==NyOffset(gmt))
            g_clock=GTS_CLOCK_NY;
         else
            if(off==(EuDst(gmt) ? 3*3600 : 2*3600))
               g_clock=GTS_CLOCK_EET;
            else
              {
               g_clock=GTS_CLOCK_FIXED;
               g_fixed_off=off;
              }
        }
     }
   g_native=(g_clock==GTS_CLOCK_NY);
  }

string ClockText(void)
  {
   if(g_native)
      return("NY close (broker)");
   if(g_clock==GTS_CLOCK_EET)
      return("NY close, from EET");
   return(StringFormat("NY close, from UTC%+d",g_fixed_off/3600));
  }

//--- closed candles of `tf`, oldest first, on the New York-close clock. With a New York-close broker this is the
//--- broker's own candles; otherwise they are rebuilt from H1 (times in the result are New York-close times)
int GetBars(const ENUM_TIMEFRAMES tf,const int count,MqlRates &out[])
  {
   int per=PeriodSeconds(tf);
   if(g_native || per<3600 || per>86400 || per%3600!=0)
      return(CopyRates(_Symbol,tf,1,count,out));
   MqlRates h[];
   int need=(int)MathMin((double)count*per/3600.0+48.0,60000.0);
   int n=CopyRates(_Symbol,PERIOD_H1,1,need,h);
   if(n<=0)
      return(n);
   datetime cur=NyBucket(TimeCurrent(),per);        // the candle still forming is left out
   ArrayResize(out,0,count+1);
   int m=0;
   for(int i=0; i<n; i++)
     {
      datetime k=NyBucket(h[i].time,per);
      if(k>=cur)
         break;
      if(m==0 || k!=out[m-1].time)
        {
         ArrayResize(out,m+1,count+1);
         out[m]=h[i];
         out[m].time=k;
         m++;
         continue;
        }
      out[m-1].high=MathMax(out[m-1].high,h[i].high);
      if(h[i].low<out[m-1].low)
        {
         out[m-1].low=h[i].low;
         out[m-1].spread=h[i].spread;                 // the spread when the low printed: the ask low for shorts
        }
      out[m-1].close=h[i].close;
      out[m-1].tick_volume+=h[i].tick_volume;
      out[m-1].real_volume+=h[i].real_volume;
     }
   if(m>count)
     {
      ArrayRemove(out,0,m-count);
      m=count;
     }
   return(m);
  }

//--- open time of the forming candle (New York-close time when converting), and seconds until it closes
datetime CurBar(void) { return(g_native ? iTime(_Symbol,InpTF,0) : NyBucket(TimeCurrent(),PeriodSeconds(InpTF))); }

int SecsToNextBar(void)
  {
   datetime now=TimeCurrent();
   return(PeriodSeconds(InpTF)-(int)(now+Shift(now)-CurBar()));
  }

//--- true range; the first bar has no previous close, so it is high - low
void TrueRange(const MqlRates &r[],const int n,double &tr[])
  {
   ArrayResize(tr,n);
   for(int i=0; i<n; i++)
     {
      double hl=r[i].high-r[i].low;
      if(i==0)
        {
         tr[i]=hl;
         continue;
        }
      double pc=r[i-1].close;
      tr[i]=MathMax(hl,MathMax(MathAbs(r[i].high-pc),MathAbs(r[i].low-pc)));
     }
  }

//--- Wilder's smoothing (TradingView ta.rma), seeded with the SMA of the first n values; EMPTY_VALUE before
void Rma(const double &x[],const int n,const int period,double &out[])
  {
   ArrayResize(out,n);
   ArrayInitialize(out,EMPTY_VALUE);
   if(n<period)
      return;
   double s=0;
   for(int i=0; i<period; i++)
      s+=x[i];
   out[period-1]=s/period;
   for(int i=period; i<n; i++)
      out[i]=(out[i-1]*(period-1)+x[i])/period;
  }

//--- UT Bot Alerts trailing line on the close
void UTBot(const MqlRates &r[],const int n,const double &atr[],const double key,double &stop[])
  {
   ArrayResize(stop,n);
   for(int i=0; i<n; i++)
     {
      double prev=(i>0 ? stop[i-1] : 0.0);
      if(atr[i]==EMPTY_VALUE)
        {
         stop[i]=(i==0 ? EMPTY_VALUE : prev);
         continue;
        }
      if(prev==EMPTY_VALUE)
         prev=0.0;
      double src=r[i].close,p1=(i>0 ? r[i-1].close : r[i].close),nloss=key*atr[i];
      if(src>prev && p1>prev)
         stop[i]=MathMax(prev,src-nloss);
      else
         if(src<prev && p1<prev)
            stop[i]=MathMin(prev,src+nloss);
         else
            stop[i]=(src>prev ? src-nloss : src+nloss);
     }
  }

//--- Supertrend direction (+1 up, -1 down; 0 before the ATR exists)
void Supertrend(const MqlRates &r[],const int n,const double &atr[],const double mult,int &dir[])
  {
   ArrayResize(dir,n);
   ArrayInitialize(dir,0);
   double up=0,dn=0,st=0;
   bool have=false;
   for(int i=0; i<n; i++)
     {
      if(atr[i]==EMPTY_VALUE)
         continue;
      double src=(r[i].high+r[i].low)/2.0;
      double ub=src+mult*atr[i],lb=src-mult*atr[i];
      if(have)
        {
         lb=(lb>dn || r[i-1].close<dn) ? lb : dn;
         ub=(ub<up || r[i-1].close>up) ? ub : up;
        }
      double d;
      if(!have)
         d=1.0;
      else
         if(st==up)
            d=(r[i].close>ub ? -1.0 : 1.0);
         else
            d=(r[i].close<lb ? 1.0 : -1.0);
      up=ub;
      dn=lb;
      st=(d<0 ? lb : ub);
      have=true;
      dir[i]=(d<0 ? 1 : -1);                       // research: trend = -direction
     }
  }

//--- daily trend: last completed D1 close vs its EMA (seeded with the SMA of the first `period` closes)
bool DailyTrend(int &dir,double &close1,double &ema1)
  {
   double c[];
   MqlRates d[];
   int n=GetBars(PERIOD_D1,D1WIN,d);                // completed days only, oldest first
   ArrayResize(c,MathMax(n,0));
   for(int i=0; i<n; i++)
      c[i]=d[i].close;
   if(n<InpTrendEMA)                              // the EMA exists from the period-th close, as in the research
      return(false);
   double s=0;
   for(int i=0; i<InpTrendEMA; i++)
      s+=c[i];
   double e=s/InpTrendEMA,k=2.0/(InpTrendEMA+1);
   for(int i=InpTrendEMA; i<n; i++)
      e+=k*(c[i]-e);
   close1=c[n-1];
   ema1=e;
   dir=(close1>e ? 1 : (close1<e ? -1 : 0));
   return(true);
  }

//+------------------------------------------------------------------+
//| Signal from the last closed signal bar: +1 buy, -1 sell, 0 none  |
//+------------------------------------------------------------------+
int Evaluate(void)
  {
   MqlRates r[];
   int n=GetBars(InpTF,WIN,r);                    // closed bars, oldest first
   if(n<MIN_BARS)
      return(0);
   double tr[],atr_ut[],atr_st[],atr_sl[],ut[];
   int st[];
   TrueRange(r,n,tr);
   Rma(tr,n,InpUTATR,atr_ut);
   Rma(tr,n,InpSTPeriod,atr_st);
   Rma(tr,n,InpStopATR,atr_sl);
   UTBot(r,n,atr_ut,InpUTKey,ut);
   Supertrend(r,n,atr_st,InpSTMult,st);
   int j=n-1;
   if(ut[j]==EMPTY_VALUE || ut[j-1]==EMPTY_VALUE || atr_sl[j]==EMPTY_VALUE)
      return(0);
   g_ut_stop=ut[j];
   g_ut_side=(r[j].close>ut[j] ? 1 : -1);
   g_st_dir=st[j];
   g_atr_stop=atr_sl[j];
   if(!DailyTrend(g_d1_dir,g_d1_close,g_d1_ema))
      return(0);
   bool ut_buy =r[j].close>ut[j] && r[j-1].close<=ut[j-1];
   bool ut_sell=r[j].close<ut[j] && r[j-1].close>=ut[j-1];
   if(ut_buy && g_d1_dir>0 && g_st_dir>0)
      return(1);
   if(ut_sell && g_d1_dir<0 && g_st_dir<0)
      return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Positions                                                        |
//+------------------------------------------------------------------+
ulong MyTicket(void)
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong t=PositionGetTicket(i);
      if(MyPosition(t))
         return(t);
     }
   return(0);
  }

string TrailKey(const ulong ticket) { return("GTS_TRAIL_"+IntegerToString((long)ticket)); }

bool ClosePosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return(true);
   MqlTradeRequest q;
   ZeroMemory(q);
   q.action=TRADE_ACTION_DEAL;
   q.symbol=_Symbol;
   q.position=ticket;
   q.volume=PositionGetDouble(POSITION_VOLUME);
   bool lng=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
   q.type=lng ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   q.price=lng ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   q.deviation=50;
   q.magic=InpMagic;
   q.type_filling=g_fok ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;
   bool ok=Send(q);
   if(ok)
      GlobalVariableDel(TrailKey(ticket));
   return(ok);
  }

//--- after any fill: if this EA's position could not reach its stop without the account hitting the broker's
//--- stop-out level (e.g. after a gap), close it at market rather than let the broker force-close it
void SurviveCheck(void)
  {
   ulong t=MyTicket();
   if(t==0 || !PositionSelectByTicket(t))
      return;
   double worst=AccountInfoDouble(ACCOUNT_EQUITY);
   double psl=PositionGetDouble(POSITION_SL),cur=PositionGetDouble(POSITION_PRICE_CURRENT);
   bool   lng=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
   if(psl>0 && (lng ? psl<cur : psl>cur))
      worst-=GAP_MULT*PositionGetDouble(POSITION_VOLUME)*LossPerLot(cur,psl);
   double so=AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
   double used=AccountInfoDouble(ACCOUNT_MARGIN);
   double floor_=AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE)==ACCOUNT_STOPOUT_MODE_PERCENT ? used*so/100.0 : so;
   if(worst<=floor_ && ClosePosition(t))
     {
      g_sig_result="closed: balance too small for SL";
      Print("Gold Trend Sentinel: the balance could not carry the position to its stop; closed at market.");
     }
  }

//--- market order with the stop attached; "placed" or why not

string OpenPosition(const bool buy)
  {
   double price=buy ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double dist=InpStopMult*g_atr_stop;
   double gap=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double spread=SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(dist<gap+spread+_Point)                       // never inside the broker's stop level or the spread: a stop
      dist=gap+spread+_Point;                       // on the wrong side of the bid/ask is rejected "Invalid stops"
   double sl=FixPrice(buy ? price-dist : price+dist);
   string why="";
   double volume=TradeVolume(price,sl,why);
   if(volume<=0)
      return(why);
   string why_not=Affordable(buy,volume,price,sl);
   if(why_not!="")
      return(why_not);
   MqlTradeRequest q;
   ZeroMemory(q);
   q.action=TRADE_ACTION_DEAL;
   q.symbol=_Symbol;
   q.volume=volume;
   q.type=buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   q.price=price;
   q.sl=sl;
   q.deviation=50;
   q.magic=InpMagic;
   q.comment="GTS";
   q.type_filling=g_fok ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;
   MqlTradeResult res;
   ZeroMemory(res);
   if(!OrderSend(q,res) || (res.retcode!=TRADE_RETCODE_DONE && res.retcode!=TRADE_RETCODE_PLACED))
     {
      why=res.retcode==TRADE_RETCODE_NO_MONEY ? "not enough margin" :
          (res.comment!="" ? res.comment : "error "+IntegerToString(GetLastError()));
      PrintFormat("Gold Trend Sentinel: %s %.2f lot not opened: %s (retcode %u)",buy ? "buy" : "sell",volume,why,res.retcode);
      return("rejected: "+why);
     }
   ulong t=MyTicket();
   if(t>0)
      GlobalVariableSet(TrailKey(t),dist);          // the trail keeps the entry's distance, across restarts
   return("placed");
  }

//--- chandelier trail, once per signal bar: best price since entry (fill and every closed bar's extreme)
void TrailStop(void)
  {
   if(!InpTrail)
      return;
   ulong t=MyTicket();
   if(t==0 || !PositionSelectByTicket(t))
      return;
   double dist=GlobalVariableCheck(TrailKey(t)) ? GlobalVariableGet(TrailKey(t)) : InpStopMult*g_atr_stop;
   bool   lng=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
   double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL);
   //--- from the start of the bar the position opened in: the research counts that bar's extreme too
   datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
   int per=PeriodSeconds(InpTF);
   datetime since=g_native ? iTime(_Symbol,InpTF,MathMax(iBarShift(_Symbol,InpTF,opened),0)) : NyBucket(opened,per);
   datetime cur=CurBar();
   if(since>=cur)
      return;                                        // opened in the current bar: nothing closed yet
   MqlRates r[];
   int n=GetBars(InpTF,(int)((cur-since)/per)+2,r);
   double best=open;
   for(int i=0; i<n; i++)
      if(r[i].time>=since)
         best=lng ? MathMax(best,r[i].high) : MathMin(best,r[i].low+r[i].spread*_Point);
   double ns=FixPrice(lng ? best-dist : best+dist);
   if(sl>0 && (lng ? ns<=sl : ns>=sl))
      return;                                        // only ever tightens
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double gap=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double freeze=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)*_Point;
   //--- the new stop is already through the price: the tested rule exits at this bar's open
   if(lng ? ns>=bid : ns<=ask)
     {
      if(ClosePosition(t))
         PrintFormat("Gold Trend Sentinel: trail stop %s passed the price, position closed",DoubleToString(ns,_Digits));
      return;
     }
   if(lng ? bid-ns<=MathMax(gap,freeze) : ns-ask<=MathMax(gap,freeze))
      return;                                        // too close for the broker now; try again next bar
   MqlTradeRequest q;
   ZeroMemory(q);
   q.action=TRADE_ACTION_SLTP;
   q.symbol=_Symbol;
   q.position=t;
   q.sl=ns;
   q.tp=PositionGetDouble(POSITION_TP);
   q.magic=InpMagic;
   Send(q);
  }

//+------------------------------------------------------------------+
//| Chart: the UT Bot line and signal markers                        |
//+------------------------------------------------------------------+

void DrawLevels(void)
  {
   if(!g_ui || !InpShowLevels || g_ut_stop<=0)
      return;
   string name=PREFIX+"ut";
   if(ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_HLINE,0,0,g_ut_stop);
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
     }
   ObjectSetDouble(0,name,OBJPROP_PRICE,g_ut_stop);
   ObjectSetInteger(0,name,OBJPROP_COLOR,g_ut_side>0 ? UiPos() : UiNeg());
   ObjectSetString(0,name,OBJPROP_TOOLTIP,"UT Bot line "+DoubleToString(g_ut_stop,_Digits));
  }

void Marker(const bool buy,const datetime t)
  {
   if(!g_ui || !InpShowLevels)
      return;
   string name=PREFIX+"m"+IntegerToString(g_markers%MARKERS);
   g_markers++;
   ObjectDelete(0,name);
   MqlRates r[];
   if(GetBars(InpTF,1,r)<1)
      return;
   double price=buy ? r[0].low : r[0].high;
   ObjectCreate(0,name,buy ? OBJ_ARROW_BUY : OBJ_ARROW_SELL,0,r[0].time-Shift(r[0].time),price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,buy ? UiPos() : UiNeg());
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,(buy ? "buy signal: " : "sell signal: ")+g_sig_result);
  }

//+------------------------------------------------------------------+
//| Status panel                                                     |
//+------------------------------------------------------------------+
string Dir(const int d,const string up,const string dn) { return(d>0 ? up : (d<0 ? dn : "-")); }

void DrawPanel(void)
  {
   if(!g_ui)
      return;
   if(g_stats_dirty)
      RecalcStats();
   g_cursor=0;
   Box("bg",0,0,UI_W,g_collapsed ? UI_HEAD : MathMax(g_rows,UI_HEAD),UiBack(),UiRule());
   Text("title",UI_PAD,5,"GOLD TREND SENTINEL",UiText());
   string ed="FREE";
   Text("ed",UI_W-UI_PAD-18-8-UI_CHAR*4,6,ed,UiAccent(),InpFontSize-1);
   Button("btn",UI_W-UI_PAD-18,4,g_collapsed ? "+" : "-");
   if(g_collapsed)
      return;
   ulong pos=MyTicket();
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   g_pdh=bid;
   g_ref_stop=InpStopMult*g_atr_stop;
   string state;
   color  sc;
   if(!g_symbol_ok)
     {
      state="XAUUSD only - idle";
      sc=UiNeg();
     }
   else
   if(!g_market_open)
     {
      state="market closed";
      sc=UiDim();
     }
   else
      if(pos>0 && PositionSelectByTicket(pos))
        {
         state=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? "in a long trade" : "in a short trade";
         sc=UiAccent();
        }
      else
        {
         state="watching for a signal";
         sc=UiText();
        }
   int y=UI_HEAD+2;
   y=Section("s1",y,"STATUS");
   y=Row("state",y,"State",state,sc);
   y=Row("lot",y,"Lot",LotText(),UiText());
   string rt=RiskText();
   y=Row("risk",y,"Risk",rt,rt=="-" ? UiDim() : RiskColor(g_risk_now));
   y=Row("spread",y,"Spread",DoubleToString(ask-bid,_Digits),UiAccent());
   y=Row("next",y,"Next check",Clock(SecsToNextBar()),UiDim());
   y=Row("clock",y,"Candles",ClockText(),g_native ? UiDim() : UiWarn());
   y=Section("s2",y,"TREND FILTERS");
   y=Row("d1",y,"Daily trend",g_d1_ema>0 ? Dir(g_d1_dir,"UP","DOWN")+StringFormat("  %+.1f%% vs EMA",100*(g_d1_close/g_d1_ema-1)) : "-",
         g_d1_dir>0 ? UiPos() : (g_d1_dir<0 ? UiNeg() : UiDim()));
   y=Row("st",y,"Supertrend",Dir(g_st_dir,"UP","DOWN"),g_st_dir>0 ? UiPos() : (g_st_dir<0 ? UiNeg() : UiDim()));
   y=Row("ut",y,"UT Bot line",g_ut_stop>0 ? Px(g_ut_stop)+(g_ut_side>0 ? "  price above" : "  price below") : "-",UiAccent());
   string allow=(g_d1_dir>0 && g_st_dir>0) ? "buys only" : ((g_d1_dir<0 && g_st_dir<0) ? "sells only" : "none (filters disagree)");
   y=Row("allow",y,"Allowed",allow,StringFind(allow,"none")==0 ? UiDim() : UiWarn());
   string ls=g_sig_time>0 ? StringFormat("%s %s",g_sig_side>0 ? "BUY" : "SELL",TimeToString(g_sig_time,TIME_DATE|TIME_MINUTES)) : "none yet";
   y=Row("last",y,"Last signal",ls,g_sig_time>0 ? (g_sig_side>0 ? UiPos() : UiNeg()) : UiDim());
   y=Row("res",y,"",g_sig_result,g_sig_result=="placed" || g_sig_result=="reversed" ? UiPos() : UiDim());
   y=Section("s3",y,"POSITION");
   string pv="-",slv="-",fl="-",rr="-";
   color  fc=UiDim();
   if(pos>0 && PositionSelectByTicket(pos))
     {
      bool lng=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
      double op=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL);
      double f=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double dist=GlobalVariableCheck(TrailKey(pos)) ? GlobalVariableGet(TrailKey(pos)) : g_ref_stop;
      pv=StringFormat("%s %s @ %s",lng ? "LONG" : "SHORT",DoubleToString(PositionGetDouble(POSITION_VOLUME),2),Px(op));
      slv=Px(sl)+(sl>0 && (lng ? sl>op : sl<op) ? "  locked in" : "");
      fl=Money(f);
      fc=Sign(f);
      if(dist>0)
         rr=StringFormat("%+.2fR",(lng ? bid-op : op-ask)/dist);
     }
   y=Row("pos",y,"Position",pv,pos>0 ? UiText() : UiDim());
   y=Row("sl",y,"Trail stop",slv,pos>0 ? UiText() : UiDim());
   y=Row("float",y,"Floating",fl,fc);
   y=Row("rnow",y,"Now",rr,pos>0 ? UiText() : UiDim());
   y=Section("s4",y,"RESULTS  (this EA, this symbol)");
   string tr=g_closed>0 ? StringFormat("%d  (%dW / %dL, %.0f%%)",g_closed,g_wins,g_closed-g_wins,100.0*g_wins/g_closed) : "none yet";
   y=Row("trades",y,"Trades",tr,g_closed>0 ? UiText() : UiDim());
   y=Row("net",y,"Net",Money(g_net),Sign(g_net));
   string pf=g_gross_loss>0 ? DoubleToString(g_gross_win/g_gross_loss,2) : (g_gross_win>0 ? "inf" : "-");
   y=Row("pf",y,"Profit factor",pf,g_closed>0 ? UiText() : UiDim());
   y=Row("today",y,"Today",Money(g_today),Sign(g_today));
   g_rows=y+UI_PAD-4;
   Box("bg",0,0,UI_W,g_rows,UiBack(),UiRule());
   if(g_panel_dirty)
     {
      ChartRedraw();
      g_panel_dirty=false;
     }
  }

//+------------------------------------------------------------------+
//| Expert events                                                    |
//+------------------------------------------------------------------+
//--- XAUUSD, with any broker prefix or suffix (XAUUSDm, XAUUSD.pro, pXAUUSD...)
bool GoldSymbol(void)
  {
   string s=_Symbol;
   StringToUpper(s);
   return(StringFind(s,"XAUUSD")>=0);
  }

int OnInit(void)
  {
   g_tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   g_vol_min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   g_vol_max=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   g_vol_step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   g_fok=(SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE)&SYMBOL_FILLING_FOK)!=0;
   g_gtc=(SymbolInfoInteger(_Symbol,SYMBOL_EXPIRATION_MODE)&SYMBOL_EXPIRATION_GTC)!=0;
   g_last_bar=0;
   //--- live and demo charts: XAUUSD only. The Strategy Tester may test any symbol (the Market's automatic
   //--- validation runs EURUSD and GBPUSD on a small account, where gold's minimum lot cannot be carried safely)
   g_symbol_ok=GoldSymbol() || MQLInfoInteger(MQL_TESTER);
   if(!GoldSymbol())
     {
      string msg=MQLInfoInteger(MQL_TESTER) ?
                 StringFormat("Gold Trend Sentinel: testing %s in the Strategy Tester; on live charts it trades XAUUSD only.",_Symbol) :
                 StringFormat("Gold Trend Sentinel works on XAUUSD charts only; it will not trade on %s.",_Symbol);
      Print(msg);
      if(!MQLInfoInteger(MQL_TESTER))
         Alert(msg);
     }
   ResolveClock();
   if(InpDebug)                                  // one line with everything a bug report needs (no account number)
      PrintFormat("DBG start: Gold Trend Sentinel %s %s, %s, signals %s, server %s, %s account, digits %d, tick %s, "
                  "lot min/step/max %s/%s/%s, stops %d, freeze %d, clock %s, terminal build %d",GTS_VERSION,
                  "Free",_Symbol,StringSubstr(EnumToString(InpTF),7),AccountInfoString(ACCOUNT_SERVER),
                  AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING ? "hedging" : "netting",
                  _Digits,DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),_Digits),
                  DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),2),DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),2),
                  DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),2),(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),
                  (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL),ClockText(),(int)TerminalInfoInteger(TERMINAL_BUILD));
   bool tester=(bool)MQLInfoInteger(MQL_TESTER);
   if(tester && InpClock==GTS_CLOCK_AUTO)
      Print("Gold Trend Sentinel: the Strategy Tester can't detect the broker's clock; New York close is assumed. ",
            "Set 'Broker server clock' for a broker on another clock.");
   PrintFormat("Gold Trend Sentinel: candles on the New York-close clock (%s)",ClockText());
   g_ui=InpShowPanel && !MQLInfoInteger(MQL_OPTIMIZATION) && (!tester || MQLInfoInteger(MQL_VISUAL_MODE));
   //--- drop trail variables of positions that no longer exist (closed while the EA was off)
   for(int i=GlobalVariablesTotal()-1; i>=0; i--)
     {
      string gv=GlobalVariableName(i);
      if(StringFind(gv,"GTS_TRAIL_")!=0)
         continue;
      ulong tk=(ulong)StringToInteger(StringSubstr(gv,10));
      if(!PositionSelectByTicket(tk))
         GlobalVariableDel(gv);
     }
   if(!tester)
      EventSetTimer(1);
   if(g_ui)
     {
      CacheClear();
      g_stats_dirty=true;
      DrawPanel();
     }
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0,PREFIX);
   CacheClear();
   ChartRedraw();
  }

void OnTick(void)
  {
   if(!g_symbol_ok)                            // not an XAUUSD chart: never trade
      return;
   datetime bar=CurBar();
   static datetime guarded=0;                  // an open trade must stay survivable to its stop; swaps or
   if(PositionsTotal()>0 && TimeCurrent()!=guarded)  // another position can drain the account: once a second
     {
      guarded=TimeCurrent();
      SurviveCheck();
     }
   if(bar==g_last_bar || (g_last_bar==0 && Bars(_Symbol,InpTF)<MIN_BARS))
     {
      if(g_ui && MQLInfoInteger(MQL_TESTER) && TimeCurrent()!=g_last_ui)
        {
         g_last_ui=TimeCurrent();
         DrawPanel();
        }
      return;
     }
   g_last_bar=bar;
   g_market_open=IsMarketOpen();
   if(!g_market_open)
     {
      g_last_bar=0;                                  // try again on the first tick of the session
      DrawPanel();
      return;
     }
   int sig=Evaluate();
   if(InpDebug)
      PrintFormat("DBG %s: ut %s side %d, supertrend %d, daily %d (close %s ema %s), atr %s, signal %d",
                  TimeToString(bar),DoubleToString(g_ut_stop,_Digits),g_ut_side,g_st_dir,g_d1_dir,
                  DoubleToString(g_d1_close,_Digits),DoubleToString(g_d1_ema,_Digits),DoubleToString(g_atr_stop,_Digits),sig);
   //--- the tested order of events: exits decided at the close (reversal), then entries, then the trail
   ulong t=MyTicket();
   int pos=0;
   if(t>0 && PositionSelectByTicket(t))
      pos=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1;
   if(sig!=0)
     {
      g_sig_time=g_native ? iTime(_Symbol,InpTF,1) : bar-PeriodSeconds(InpTF)-Shift(TimeCurrent()); // server time
      g_sig_side=sig;
      if(pos==sig)
        {
         g_sig_result="already in this direction";
         TrailStop();                                // the research tightens the trail on this bar too
        }
      else
        {
         bool reversed=false;
         if(pos==-sig)
            reversed=ClosePosition(t);
         if(pos==0 || reversed)
           {
            g_sig_result=OpenPosition(sig>0);
            if(reversed && g_sig_result=="placed")
               g_sig_result="reversed";
           }
         else
            g_sig_result="could not close the old trade";
        }
      Marker(sig>0,g_sig_time);
      if(InpDebug)
         PrintFormat("DBG %s: signal %s -> %s",TimeToString(bar),sig>0 ? "BUY" : "SELL",g_sig_result);
     }
   else
      TrailStop();
   DrawLevels();
   DrawPanel();
  }

void OnTimer(void)
  {
   if(g_ui && TimeLocal()-g_cache_reset>=60)
     {
      g_cache_reset=TimeLocal();
      CacheClear();
     }
   DrawPanel();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)
      return;
   g_stats_dirty=true;
   if(trans.position>0 && !PositionSelectByTicket(trans.position))
      GlobalVariableDel(TrailKey(trans.position));   // closed (by us or by the broker's stop): drop its trail
   SurviveCheck();
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id==CHARTEVENT_OBJECT_CLICK && sparam==PREFIX+"btn")
     {
      g_collapsed=!g_collapsed;
      ObjectsDeleteAll(0,PREFIX+"s");
      for(int i=ObjectsTotal(0,0,OBJ_LABEL)-1; i>=0; i--)
        {
         string n=ObjectName(0,i,0,OBJ_LABEL);
         if(StringFind(n,PREFIX)==0 && n!=PREFIX+"title" && n!=PREFIX+"ed")
            ObjectDelete(0,n);
        }
      CacheClear();
      DrawPanel();
      ChartRedraw();
     }
  }
//+------------------------------------------------------------------+
