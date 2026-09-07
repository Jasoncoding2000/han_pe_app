"""V-shaped recovery scanner — scans all A-share stocks for V-shaped price patterns."""
import urllib.request
import json
import time
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

SINA_BASE = 'https://vip.stock.finance.sina.com.cn'
KLINE_BASE = 'https://quotes.sina.cn'
HEADERS = {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://finance.sina.com.cn'}

# === Algorithm parameters ===
MIN_DROP_PCT = 20       # Peak→bottom decline ≥ 20%
MIN_RECOVERY_PCT = 30   # Bottom→current recovers ≥ 30% of the drop
MIN_LEG_DAYS = 15       # Each leg must have ≥ 15 trading days

# === Priority filters ===
MIN_R2 = 0.50           # Both legs R² ≥ 0.50 (clean trends)
MAX_BOTTOM_AGE = 90     # Bottom must be within last 90 trading days
MAX_RECOVERY_PCT = 100  # Recovery < 100% (V still in progress)


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


def fetch_sector_stocks(node):
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
                    'industry': item.get('industryname', ''),
                })
            except (ValueError, TypeError):
                pass
        if len(data) < 80:
            break
        page += 1
    return stocks


def fetch_kline(code):
    sym = ('sh' if code.startswith('6') else 'sz') + code
    url = (f'{KLINE_BASE}/cn/api/jsonp_v2.php/var%20_kl=/'
           f'CN_MarketDataService.getKLineData?symbol={sym}&scale=240&ma=no&datalen=250')
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
            days.append({'close': float(d['close']), 'volume': float(d['volume'])})
        except (ValueError, TypeError, KeyError):
            pass
    return days


def r_squared(values):
    """Coefficient of determination (R²) for linear regression."""
    n = len(values)
    if n < 3:
        return 0.0
    mean_y = sum(values) / n
    ss_tot = sum((y - mean_y) ** 2 for y in values)
    if ss_tot < 1e-12:
        return 0.0
    ss_res = 0.0
    for i, y in enumerate(values):
        y_hat = values[0] + (values[-1] - values[0]) * i / (n - 1)
        ss_res += (y - y_hat) ** 2
    return max(0.0, 1.0 - ss_res / ss_tot)


def detect_vshape(days):
    """Detect V-shaped recovery pattern in daily k-line data."""
    if len(days) < 60:
        return None

    closes = [d['close'] for d in days]
    n = len(closes)

    # Find the bottom (lowest close)
    bottom_val = min(closes)
    bottom_idx = closes.index(bottom_val)

    # Ensure enough data on both sides for meaningful legs
    if bottom_idx < MIN_LEG_DAYS or bottom_idx > n - MIN_LEG_DAYS - 1:
        return None

    # Find the peak (highest close before the bottom)
    peak_val = max(closes[:bottom_idx + 1])
    peak_idx = closes.index(peak_val)

    # Ensure peak is well before bottom (at least MIN_LEG_DAYS apart)
    if bottom_idx - peak_idx < MIN_LEG_DAYS:
        return None

    current = closes[-1]

    # Drop depth: peak → bottom
    drop_pct = (peak_val - bottom_val) / peak_val * 100
    if drop_pct < MIN_DROP_PCT:
        return None

    # Recovery: bottom → current as % of the drop
    recovery_amount = current - bottom_val
    drop_amount = peak_val - bottom_val
    if drop_amount <= 0:
        return None
    recovery_pct = recovery_amount / drop_amount * 100
    if recovery_pct < MIN_RECOVERY_PCT:
        return None

    # Slope comparison: ascent rate must exceed descent rate (% per day relative to bottom)
    descent_days = bottom_idx - peak_idx
    ascent_days = n - 1 - bottom_idx
    if descent_days < 1 or ascent_days < 1:
        return None

    descent_rate = drop_pct / descent_days      # avg % drop per day
    ascent_rate = (recovery_amount / bottom_val * 100) / ascent_days  # avg % rise per day
    if ascent_rate <= descent_rate:
        return None

    # R² for both legs
    r2_descent = r_squared(closes[peak_idx:bottom_idx + 1])
    r2_ascent = r_squared(closes[bottom_idx:])

    # --- Priority filters ---
    if r2_descent < MIN_R2 or r2_ascent < MIN_R2:
        return None
    bottom_age = n - 1 - bottom_idx  # trading days since bottom
    if bottom_age > MAX_BOTTOM_AGE:
        return None
    if recovery_pct >= MAX_RECOVERY_PCT:
        return None

    return {
        'peak_idx': peak_idx, 'peak_val': peak_val,
        'bottom_idx': bottom_idx, 'bottom_val': bottom_val,
        'current': current,
        'drop_pct': drop_pct,
        'recovery_pct': recovery_pct,
        'descent_days': descent_days, 'ascent_days': ascent_days,
        'descent_rate': descent_rate, 'ascent_rate': ascent_rate,
        'r2_descent': r2_descent, 'r2_ascent': r2_ascent,
        'bottom_age': bottom_age,
        'steepness_ratio': ascent_rate / descent_rate if descent_rate > 0 else 0,
    }


def main():
    t0 = time.time()
    print('=' * 70)
    print('  V-Shaped Recovery Scanner')
    print(f'  Drop >= {MIN_DROP_PCT}% | Recovery >= {MIN_RECOVERY_PCT}% & < {MAX_RECOVERY_PCT}%')
    print(f'  Ascent > Descent | Both R2 >= {MIN_R2} | Bottom <= {MAX_BOTTOM_AGE}d ago')
    print('=' * 70)

    # 1. Fetch sectors
    print('\n[1/3] Fetching sectors...')
    sectors = fetch_sectors()
    print(f'  Found {len(sectors)} sectors')

    # 2. Fetch all stocks (concurrent)
    print('\n[2/3] Fetching stocks...')
    all_stocks = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(fetch_sector_stocks, label): name for label, name in sectors}
        for i, fut in enumerate(as_completed(futures), 1):
            name = futures[fut]
            try:
                stocks = fut.result()
                all_stocks.extend(stocks)
                if i % 10 == 0 or i == len(sectors):
                    print(f'  [{i}/{len(sectors)}] {name}  (total: {len(all_stocks)})', end='\r')
            except Exception:
                pass
    print(f'\n  Total stocks: {len(all_stocks)}')

    # Deduplicate by code
    seen = set()
    unique = []
    for s in all_stocks:
        if s['code'] not in seen:
            seen.add(s['code'])
            unique.append(s)
    print(f'  Unique: {len(unique)}')

    # Filter out ST/*ST, delisting (退), and B-shares (200xxx)
    import re
    filtered = []
    for s in unique:
        name = s['name']
        code = s['code']
        if re.search(r'ST|st|\*ST|退', name, re.IGNORECASE):
            continue
        if code.startswith('200'):
            continue
        filtered.append(s)
    print(f'  After excluding ST/B-shares: {len(filtered)}')

    # 3. Scan for V-shapes (concurrent)
    print(f'\n[3/3] Scanning {len(filtered)} stocks for V-shapes...')
    candidates = []
    scanned = 0

    def scan_one(stock):
        days = fetch_kline(stock['code'])
        result = detect_vshape(days)
        return stock, result

    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(scan_one, s) for s in filtered]
        for fut in as_completed(futures):
            scanned += 1
            if scanned % 100 == 0 or scanned == len(filtered):
                print(f'  Scanned {scanned}/{len(filtered)}  (found {len(candidates)})', end='\r')
            try:
                stock, result = fut.result()
                if result:
                    candidates.append((stock, result))
            except Exception:
                pass

    elapsed = time.time() - t0
    print(f'\n  Scan complete in {elapsed:.0f}s')

    # Sort by steepness ratio descending (strongest V first)
    candidates.sort(key=lambda x: x[1]['steepness_ratio'], reverse=True)

    # 4. Results
    print(f'\n{"=" * 70}')
    print(f'  V-SHAPED RECOVERY CANDIDATES: {len(candidates)}')
    print(f'{"=" * 70}')

    for i, (stock, r) in enumerate(candidates, 1):
        print(f'\n  #{i}  {stock["code"]}  {stock["name"]}')
        print(f'    Peak:    {r["peak_val"]:.2f}  (day {r["peak_idx"]})')
        print(f'    Bottom:  {r["bottom_val"]:.2f}  (day {r["bottom_idx"]}, {r["bottom_age"]}d ago)')
        print(f'    Current: {r["current"]:.2f}')
        print(f'    Drop:    {r["drop_pct"]:.1f}%  over {r["descent_days"]}d  '
              f'(rate: {r["descent_rate"]:.2f}%/d  R2={r["r2_descent"]:.2f})')
        print(f'    Recovery:{r["recovery_pct"]:.0f}% of drop  over {r["ascent_days"]}d  '
              f'(rate: {r["ascent_rate"]:.2f}%/d  R2={r["r2_ascent"]:.2f})')
        print(f'    Steepness ratio: {r["steepness_ratio"]:.2f}x')

    print(f'\n{"=" * 70}')


if __name__ == '__main__':
    main()
