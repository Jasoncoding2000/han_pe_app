"""
Verify the FULL composite + upbend pipeline matches the app's 上折 tab.
Fetches top stocks by worst rank, then applies trend gate (30d/60d slope) 
on their k-lines — identical to the app's TrendEngine.compare.
"""
import sys, json, re, time
import urllib.request
import numpy as np

sys.stdout.reconfigure(encoding='utf-8')

SINA_BASE = 'https://vip.stock.finance.sina.com.cn'
KLINE_BASE = 'https://quotes.sina.cn'
HEADERS = {'User-Agent': 'Mozilla/5.0'}
RECENT_DAYS = 30
PRIOR_DAYS = 60

def get_gbk(path, retries=3):
    url = SINA_BASE + path
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=15) as resp:
                return resp.read().decode('gbk', errors='replace')
        except Exception as e:
            if attempt < retries: time.sleep(attempt)
    return None

def fetch_kline(code, datalen=250):
    sym = ('sh' if code.startswith('6') else 'sz') + code
    path = f'/cn/api/jsonp_v2.php/var%20_kl=/CN_MarketDataService.getKLineData?symbol={sym}&scale=240&ma=no&datalen={datalen}'
    try:
        req = urllib.request.Request(KLINE_BASE + path, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=15) as resp:
            text = resp.read().decode('utf-8', errors='replace')
    except Exception:
        return []
    start = text.find('[')
    end = text.rfind(']')
    if start < 0 or end <= start:
        return []
    data = json.loads(text[start:end+1])
    return [float(d['close']) for d in data if d.get('close')]

def slope(closes):
    n = len(closes)
    if n < 5: return 0.0
    x = np.arange(n, dtype=float)
    y = np.array(closes, dtype=float)
    mean_x = x.mean()
    mean_y = y.mean()
    cov = ((x - mean_x) * (y - mean_y)).sum()
    var_x = ((x - mean_x) ** 2).sum()
    if var_x < 1e-12: return 0.0
    return (cov / var_x) / mean_y * 100  # % per day

def upbend_pass(closes):
    """Same as TrendEngine.compare / engine trend_pass: recent slope > 0 AND > prior slope."""
    needed = RECENT_DAYS + PRIOR_DAYS
    if len(closes) < needed: return False, 0, 0
    recent = closes[-RECENT_DAYS:]
    prior = closes[-needed:-RECENT_DAYS]
    rs = slope(recent)
    ps = slope(prior)
    return (rs > 0 and rs > ps), rs, ps

def main():
    print("=== Composite + Upbend: Full strategy verification ===\n")
    # Quick: just get sector/stock data and compute top-N, then check upbend
    from screener_check import fetch_sectors, fetch_sector_stocks, median
    print('Fetching sectors and stocks...')
    sectors = fetch_sectors()
    all_stocks = []
    for i, s in enumerate(sectors):
        stocks = fetch_sector_stocks(s['label'], s['name'])
        all_stocks.extend(stocks)
    print(f'  {len(all_stocks)} stocks fetched')

    # Same filter/compute pipeline as screener_check
    df = [r for r in all_stocks
          if re.match(r'^(60|00[0-3])', r['code'])
          and not re.search(r'ST|st|\*ST|退', r['name'], re.IGNORECASE)
          and r['price'] > 0 and r['industry']]

    pe_groups, pb_groups = {}, {}
    for r in df:
        ind = r['industry']
        if r['pe'] > 0: pe_groups.setdefault(ind, []).append(r['pe'])
        if r['pb'] > 0: pb_groups.setdefault(ind, []).append(r['pb'])
    med_pe = {k: median(v) for k, v in pe_groups.items()}
    med_pb = {k: median(v) for k, v in pb_groups.items()}

    valid = []
    for r in df:
        if r['pe'] <= 0 or r['pb'] <= 0: continue
        mp = med_pe.get(r['industry'])
        mb = med_pb.get(r['industry'])
        if not mp or not mb or mp <= 0 or mb <= 0: continue
        hanpe = r['pe'] / mp
        hanpb = r['pb'] / mb
        worst = max(hanpe, hanpb)
        if worst > 0 and np.isfinite(worst):
            valid.append({**r, 'hanpe': hanpe, 'hanpb': hanpb, 'worst': worst})

    valid.sort(key=lambda x: x['worst'])
    best = {}
    for v in valid:
        if v['code'] not in best or v['worst'] < best[v['code']]['worst']:
            best[v['code']] = v
    ranked = sorted(best.values(), key=lambda x: x['worst'])
    for i, v in enumerate(ranked):
        v['rank'] = i + 1

    # Take top 20 and check upbend for each
    top = [v for v in ranked if v['worst'] < 0.3]
    if len(top) < 10:
        top = ranked[:20]  # expand if fewer than 10 pass threshold

    print(f'\nChecking upbend for top {min(len(top), 20)} stocks...')
    print(f'{"Rank":<5} {"Code":<8} {"Name":<10} {"Worst":>7} {"UPBEND?":<9} {"RecSlope":>9} {"PriSlope":>9}  Detail')
    print('-' * 95)

    passed = []
    for v in top[:20]:
        time.sleep(0.3)  # be polite to API
        closes = fetch_kline(v['code'])
        ok, rs, ps = upbend_pass(closes)
        mark = 'PASS' if ok else 'fail'
        detail = ''
        if not ok:
            if rs <= 0: detail = f'recent slope {rs:.3f}% <= 0 (not rising)'
            elif rs <= ps: detail = f'recent {rs:.3f} <= prior {ps:.3f} (not steepening)'
            else: detail = 'insufficient data' if len(closes) < 90 else '?'
        print(f'{v["rank"]:<5} {v["code"]:<8} {v["name"]:<10} {v["worst"]:>7.3f} {mark:<9} {rs:>+9.3f} {ps:>+9.3f}  {detail}')
        if ok:
            passed.append(v)

    print(f'\n=== RESULT: {len(passed)} stocks pass BOTH worst<0.3 AND upbend ===')
    print('These should appear on the 上折 tab:')
    for v in passed:
        print(f'  #{v["rank"]} {v["code"]} {v["name"]}  worst={v["worst"]:.3f}')


if __name__ == '__main__':
    main()
