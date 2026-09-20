"""Sequential Gate: hanPE (intact) + simple trend comparison — LIVE data from Sina.

Gate 1 (Value):  hanPE < 0.3  (UNCHANGED)
Gate 2 (Trend):  Recent rising slope > prior falling/flat slope
"""
import urllib.request
import json
import time
import re
import statistics
from concurrent.futures import ThreadPoolExecutor, as_completed

SINA_BASE = 'https://vip.stock.finance.sina.com.cn'
KLINE_BASE = 'https://quotes.sina.cn'
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
    'Referer': 'https://finance.sina.com.cn/',
    'Accept': '*/*',
}

HANPE_THRESHOLD = 0.3
RECENT_DAYS = 30
PRIOR_DAYS = 60


def fetch(url, encoding='utf-8', retries=2):
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=15) as resp:
                raw = resp.read()
                return raw.decode(encoding) if encoding else raw
        except Exception:
            if attempt == retries:
                return None
            time.sleep(0.5)


def fetch_sectors():
    text = fetch(f'{SINA_BASE}/q/view/newSinaHy.php', encoding='gbk')
    if not text:
        return []
    start = text.index('{')
    data = json.loads(text[start:])
    sectors = []
    for label, value in data.items():
        parts = value.split(',')
        sectors.append((label, parts[1] if len(parts) > 1 else label))
    return sectors


def fetch_sector_stocks(node, industry_name=''):
    stocks = []
    page = 1
    while True:
        url = (f'{SINA_BASE}/quotes_service/api/json_v2.php/'
               f'Market_Center.getHQNodeData?page={page}&num=80&sort=symbol&asc=1&node={node}&_s_r_a=page')
        text = fetch(url, encoding='gbk')
        if not text or text.strip() == '':
            break
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            break
        if not data:
            break
        for item in data:
            sym = item.get('symbol', '').replace('sh', '').replace('sz', '')
            code = sym.zfill(6)
            try:
                stocks.append({
                    'code': code,
                    'name': item.get('name', ''),
                    'price': float(item.get('trade', 0)),
                    'pe': float(item.get('per', 0)),
                    'turnover': float(item.get('turnoverratio', 0)),
                    'industry': industry_name,
                })
            except (ValueError, TypeError):
                pass
        if len(data) < 80:
            break
        page += 1
    return stocks


def fetch_kline(code, datalen=250):
    sym = ('sh' if code.startswith('6') else 'sz') + code
    url = (f'{KLINE_BASE}/cn/api/jsonp_v2.php/var%20_kl=/'
           f'CN_MarketDataService.getKLineData?symbol={sym}&scale=240&ma=no&datalen={datalen}')
    text = fetch(url)
    if not text:
        return []
    s, e = text.find('['), text.rfind(']')
    if s < 0 or e <= s:
        return []
    try:
        data = json.loads(text[s:e+1])
    except json.JSONDecodeError:
        return []
    days = []
    for d in data:
        try:
            days.append({'day': d['day'], 'close': float(d['close']), 'volume': float(d['volume'])})
        except (ValueError, TypeError, KeyError):
            pass
    return days


def slope_pct(closes):
    """Linear regression slope as % per day."""
    n = len(closes)
    if n < 5:
        return 0.0
    import numpy as np
    y = np.array(closes, dtype=float)
    x = np.arange(n, dtype=float)
    mean_x, mean_y = x.mean(), y.mean()
    cov = ((x - mean_x) * (y - mean_y)).sum()
    var = ((x - mean_x) ** 2).sum()
    if var < 1e-12:
        return 0.0
    return (cov / var) / mean_y * 100


def main():
    t0 = time.time()
    print('=' * 70)
    print('  hanPE + Trend Comparison (LIVE Sina data)')
    print(f'  Gate 1: hanPE < {HANPE_THRESHOLD}  (UNCHANGED)')
    print(f'  Gate 2: slope(last {RECENT_DAYS}d) > slope(prior {PRIOR_DAYS}d)')
    print('=' * 70)

    # --- Fetch sectors ---
    print('\n[1/4] Fetching sectors...')
    sectors = fetch_sectors()
    print(f'  Found {len(sectors)} sectors')

    # --- Fetch all stocks ---
    print('\n[2/4] Fetching stocks...')
    all_stocks = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(fetch_sector_stocks, label, name): name for label, name in sectors}
        for i, fut in enumerate(as_completed(futures), 1):
            try:
                stocks = fut.result()
                all_stocks.extend(stocks)
                if i % 10 == 0 or i == len(sectors):
                    print(f'  [{i}/{len(sectors)}] sectors done  (total: {len(all_stocks)})', end='\r')
            except Exception:
                pass
    print(f'\n  Total: {len(all_stocks)}')

    # Deduplicate
    seen = set()
    unique = []
    for s in all_stocks:
        if s['code'] not in seen:
            seen.add(s['code'])
            unique.append(s)
    print(f'  Unique: {len(unique)}')

    # Filter ST, B-shares, invalid
    filtered = []
    for s in unique:
        if re.search(r'ST|st|\*ST|退', s['name'], re.IGNORECASE):
            continue
        if s['code'].startswith('200'):
            continue
        if s['price'] <= 0 or not s['industry']:
            continue
        filtered.append(s)
    print(f'  After filters: {len(filtered)}')

    # --- Gate 1: hanPE ---
    print('\n[3/4] Gate 1: Computing hanPE...')
    industry_pe = {}
    for s in filtered:
        if s['pe'] > 0:
            industry_pe.setdefault(s['industry'], []).append(s['pe'])
    industry_median = {ind: statistics.median(pes) for ind, pes in industry_pe.items()}

    for s in filtered:
        if s['pe'] > 0 and s['industry'] in industry_median:
            s['industry_median_pe'] = industry_median[s['industry']]
            s['hanpe'] = s['pe'] / s['industry_median_pe']
        else:
            s['hanpe'] = 999.0

    hanpe_cands = [s for s in filtered if 0 < s['hanpe'] < HANPE_THRESHOLD]
    hanpe_dict = {}
    for s in hanpe_cands:
        if s['code'] not in hanpe_dict or s['hanpe'] < hanpe_dict[s['code']]['hanpe']:
            hanpe_dict[s['code']] = s
    hanpe_cands = sorted(hanpe_dict.values(), key=lambda x: x['hanpe'])
    print(f'  hanPE < {HANPE_THRESHOLD}: {len(hanpe_cands)} candidates')

    # --- Gate 2: Trend comparison ---
    print(f'\n[4/4] Gate 2: Fetching k-line & comparing trends for {len(hanpe_cands)} stocks...')
    results = []
    scanned = 0

    def scan_one(stock):
        days = fetch_kline(stock['code'], datalen=250)
        return stock, days

    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(scan_one, s) for s in hanpe_cands]
        for fut in as_completed(futures):
            scanned += 1
            if scanned % 20 == 0 or scanned == len(hanpe_cands):
                print(f'  Scanned {scanned}/{len(hanpe_cands)}  (found {len(results)})', end='\r')
            try:
                stock, days = fut.result()
                if len(days) < RECENT_DAYS + PRIOR_DAYS:
                    continue
                closes = [d['close'] for d in days]
                recent_closes = closes[-RECENT_DAYS:]
                prior_closes = closes[-(RECENT_DAYS + PRIOR_DAYS):-RECENT_DAYS]
                recent_sl = slope_pct(recent_closes)
                prior_sl = slope_pct(prior_closes)
                if recent_sl > prior_sl:
                    results.append({
                        **stock,
                        'recent_slope': recent_sl,
                        'prior_slope': prior_sl,
                        'slope_diff': recent_sl - prior_sl,
                        'recent_chg': (recent_closes[-1] / recent_closes[0] - 1) * 100,
                        'prior_chg': (prior_closes[-1] / prior_closes[0] - 1) * 100,
                        'current': closes[-1],
                        'latest_day': days[-1]['day'],
                    })
            except Exception:
                pass

    results.sort(key=lambda x: x['slope_diff'], reverse=True)
    elapsed = time.time() - t0

    # --- Output ---
    rising = [r for r in results if r['recent_slope'] > 0]
    falling_improving = [r for r in results if r['recent_slope'] <= 0]

    print(f'\n\n{"=" * 70}')
    print(f'  FILTERING FUNNEL')
    print(f'{"=" * 70}')
    print(f'  All stocks (excl ST/B):   {len(filtered)}')
    print(f'  Gate 1 (hanPE < {HANPE_THRESHOLD}):    {len(hanpe_cands)}')
    print(f'  Gate 2 (trend improving): {len(results)}')
    print(f'    Currently rising:       {len(rising)}')
    print(f'    Falling but improving:  {len(falling_improving)}')

    if results:
        print(f'\n{"=" * 70}')
        print(f'  RESULTS: {len(results)} stocks  (data as of {results[0]["latest_day"]})')
        print(f'{"=" * 70}')
        for i, r in enumerate(results, 1):
            trend = '↑' if r['recent_slope'] > 0 else '↓'
            print(f'\n  #{i:3d}  {r["code"]}  {r["name"]:<8s}  {trend}  hanPE={r["hanpe"]:.3f}  PE={r["pe"]:.1f}  IndPE={r["industry_median_pe"]:.1f}')
            print(f'    {r["industry"]}')
            print(f'    Prior {PRIOR_DAYS}d: {r["prior_chg"]:+.1f}%  (slope={r["prior_slope"]:+.3f}%/d)')
            print(f'    Recent {RECENT_DAYS}d: {r["recent_chg"]:+.1f}%  (slope={r["recent_slope"]:+.3f}%/d)')
            print(f'    Improvement: {r["slope_diff"]:+.3f}%/d')

    print(f'\n{"=" * 70}')
    print(f'  Done in {elapsed:.0f}s')
    print(f'{"=" * 70}')


if __name__ == '__main__':
    main()
